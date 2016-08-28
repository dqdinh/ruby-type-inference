#!/usr/bin/env ruby

require 'logger'
require 'set'
require 'sqlite3'

class TypeTracker
  @@INSERT = "INSERT OR REPLACE INTO signatures VALUES('%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s')"

  def initialize
    @logger = Logger.new($stdout)
    @signatures = Hash.new { |h, k| h[k] = Array.new }
    @pending_inserts = Set.new
    @db_connection = SQLite3::Database.open(__dir__ + '/CallStat.db')
    @method_inspector = MethodInspector.new

    @trace = TracePoint.trace(:call, :return, :raise) do |tp|
      case tp.event
        when :call
          handle_call(tp)
        when :return
          handle_return(tp)
        else
          @signatures[Thread.current.object_id].pop
      end
    end
    @trace.disable
  end

  def get_tp
    @trace
  end

  def flush
    @pending_inserts.each do | method_name, receiver_name, args_type_name, method, return_type_name,
                               gem_name, gem_version, visibility |
      args_info = @method_inspector.get_params_default_values_from_cache(method).inject([]) do |pt, p|
        pt << "#{p[0]},#{p[1]},#{p[2].class}"
      end.join(';')

      sql = @@INSERT % [method_name, receiver_name, args_type_name, args_info, return_type_name,
                        gem_name, gem_version, visibility]
      @logger.info(sql)
      @db_connection.execute(sql)
    end

    @pending_inserts.clear
  end

  private
  def handle_call(tp)
    binding = tp.binding
    method = binding.receiver.method(tp.method_id)
    args_type_name = method.parameters.inject([]) do |pt, p|
      pt << binding.local_variable_get(p[1]).class if p[1] && binding.local_variable_defined?(p[1])
    end.join(';')

    @signatures[Thread.current.object_id].push([method, args_type_name])
  end

  private
  def handle_return(tp)
    method, args_type_name = @signatures[Thread.current.object_id].pop

    if method
      method_name = tp.method_id
      receiver_name = tp.defined_class.name ? tp.defined_class : tp.defined_class.superclass
      return_type_name = tp.return_value.class

      matches = tp.path.scan(/\w+-\d+\.\d+\.\d+/)
      gem_name, gem_version = matches[2] ? matches[2].split('-') : ['', '']

      if tp.defined_class.public_method_defined?(tp.method_id)
        visibility = 'PUBLIC'
      elsif tp.defined_class.protected_method_defined?(tp.method_id)
        visibility = 'PROTECTED'
      else
        visibility = 'PRIVATE'
      end

      @pending_inserts << [method_name, receiver_name, args_type_name, method, return_type_name,
                           gem_name, gem_version, visibility]
    end
  end
end

class MethodInspector
  def initialize
    @params_default_values_cache = Hash.new { |cache, method| cache[method] = get_params_default_values(method) }

    @init_variables_inspector = TracePoint.trace(:call) do |tp|
      if tp.method_id == @current_method
        binding = tp.binding
        params = tp.defined_class.instance_method(tp.method_id).parameters
        params.each do |param|
          param << binding.local_variable_get(param[1]) if param[1] && binding.local_variable_defined?(param[1])
        end
        raise InspectException.new(params)
      end
    end
    @init_variables_inspector.disable
  end


  def get_params_default_values_from_cache(method)
    @params_default_values_cache[method]
  end

  def get_params_default_values(method)
    if method.parameters.any? { |param| param[0] == :opt || param[0] == :key }
      args = []
      kwargs = {}
      method.parameters.each do |param|
        if param[0] == :req
          args << nil
        elsif param[0] == :keyreq
          kwargs[param[1]] = nil
        end
      end
      args << kwargs unless kwargs.empty?

      begin
        @current_method = method.name
        @init_variables_inspector.enable do
          method.call(*args)
        end
      rescue InspectException => inspection
        inspection.inspection_result
      end
    else
      params = method.parameters
      params.each do |param|
        param << nil
      end
      params
    end
  end
end

class InspectException < StandardError
  attr_reader :inspection_result

  def initialize(inspection_result)
    @inspection_result = inspection_result
    super
  end
end

if ARGV.empty?
  puts 'Must specify a script to run'
  exit(1)
end

abs_prog_script = File.expand_path(ARGV.shift)

type_tracker = TypeTracker.new
type_tracker.get_tp.enable do
  load abs_prog_script
end

type_tracker.flush