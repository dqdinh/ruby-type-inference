#!/usr/bin/env ruby

require 'logger'
require 'set'
require 'socket'
require 'json'
require 'json'
require 'thread'
require 'singleton'

require 'arg_scanner'

include ArgScanner

class RSignature

  def to_json

    return JSON.generate({
                             :method_name => @method_name.to_s,
                             :call_info_argc => @call_info_argc.to_s,
                             :call_info_mid => @call_info_mid.to_s,
                             :call_info_kw_args => @call_info_kw_args.to_s,
                             :receiver_name => @receiver_name.to_s,
                             :args_type_name => @args_type_name.to_s,
                             :args_info => @args_info.to_s,
                             :return_type_name => @return_type_name.to_s,
                             :gem_name => @gem_name.to_s,
                             :gem_version => @gem_version.to_s,
                             :visibility => @visibility.to_s,
                             :path => @path.to_s,
                             :lineno => @lineno.to_s
                         })
  end

  def initialize(method_name, receiver_name, args_type_name, args_info, return_type_name, gem_name, gem_version, visibility, call_info_mid, call_info_argc, call_info_kw_args, path, lineno)
    @method_name = method_name
    @receiver_name = receiver_name
    @args_type_name = args_type_name
    @args_info = args_info
    @return_type_name = return_type_name
    @gem_name = gem_name
    @gem_version = gem_version
    @visibility = visibility
    @call_info_mid = call_info_mid
    @call_info_argc = call_info_argc
    @call_info_kw_args = call_info_kw_args
    @path = path
    @lineno = lineno
  end

end

class TypeTracker
  include Singleton

  # def start_control(host, port)
  #   socket_thread = Thread.new do
  #     begin
  #       host ||= '127.0.0.1'
  #       socket = TCPSocket.new(host, port)
  #
  #       while (true) do
  #
  #         @mutex.synchronize {
  #           if(@socketQueue.size() > 0)
  #             @tempQueue = @socketQueue
  #             @socketQueue = Queue.new
  #           end
  #         }
  #
  #         with_mutex do
  #           flag = @tempQueue.empty?
  #         end
  #
  #         while(!flag)
  #           with_mutex{ val = @tempQueue.pop }
  #           socket.puts(val);
  #           with_mutex{ flag = @tempQueue.empty? }
  #
  #         end
  #
  #         sleep(0.3)
  #       end
  #
  #     rescue Exception => e
  #       puts e.message
  #       p 'Error'
  #     end
  #   end
  #   socket_thread
  # end

  def initialize

    @socketQueue = Queue.new
    @tempQueue = Queue.new
    @signatures = Array.new
    @cache = Set.new
    @socket = TCPSocket.new('127.0.0.1', 7777)
    @mutex = Mutex.new

    TracePoint.trace(:call, :return, :raise) do |tp|
      begin
        case tp.event
          when :call
            handle_call(tp)
          when :return
            handle_return(tp)
          else
            signatures.pop
        end
      rescue NameError, NoMethodError
        signatures.push([nil, nil, nil]) if tp.event == :call
      end
    end
  end

  attr_reader :socketQueue
  attr_reader :signatures
  attr_reader :cache
  attr_reader :socket

  at_exit do
    socket = TCPSocket.new('127.0.0.1', 7777)
    socket.puts('break connection')
  end

  private
  def handle_call(tp)

    binding = tp.binding

    method = tp.defined_class.instance_method(tp.method_id)

    path = tp.path
    lineno = tp.lineno

    args_type_name = method.parameters.inject([]) do |pt, p|
      pt << (p[1] ? binding.local_variable_get(p[1]).class : NilClass)
    end.join(';')

    args_info = method.parameters.inject([]) do |pt, p|
      pt << "#{p[0]},#{p[1]},#{p[1] ? (binding.local_variable_get(p[1]).class.to_s) : NilClass}"
    end.join(';')

    if((args_info.include? 'opt,') || (args_info.include? 'key,'))
      call_info = getCallinfo

      call_info_mid = call_info[/\S*:/].chop
      call_info_argc = call_info[/\:\d*/]
      call_info_argc[0] = ''
      call_info_kw_args = call_info.partition('kw:[').last.chomp(']')
    else
      call_info_mid = 'nil'
      call_info_argc = 0
      call_info_kw_args = 'nil'
    end


    signatures.push([method, args_type_name, args_info, call_info_mid, call_info_argc, call_info_kw_args, path, lineno])


  end

  private
  def handle_return(tp)
    method, args_type_name, args_info, call_info_mid, call_info_argc, call_info_kw_args, path, lineno = signatures.pop

    if method
      method_name = tp.method_id
      receiver_name = tp.defined_class.name ? tp.defined_class : tp.defined_class.superclass
      return_type_name = tp.return_value.class.to_s

      key = [method, args_type_name, call_info_mid, return_type_name, call_info_argc, call_info_kw_args, path, lineno].hash

      if cache.add?(key)
        matches = tp.path.scan(/\w+-\d+(?:\.\d+)+/)
        gem_name, gem_version = matches[0] ? matches[0].split('-') : ['', '']

        if tp.defined_class.public_method_defined?(tp.method_id)
          visibility = 'PUBLIC'
        elsif tp.defined_class.protected_method_defined?(tp.method_id)
          visibility = 'PROTECTED'
        else
          visibility = 'PRIVATE'
        end

        message = RSignature.new(method_name, receiver_name, args_type_name, args_info, return_type_name, gem_name, gem_version, visibility, call_info_mid, call_info_argc, call_info_kw_args, path, lineno)

        @mutex.synchronize{
          json_mes = message.to_json
          #puts json_mes
          socket.puts(json_mes)
        }
      end

    end
  end

end

type_tracker = TypeTracker.instance