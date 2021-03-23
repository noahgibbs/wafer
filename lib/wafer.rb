#require "wafer/version"

require 'socket'
require 'cgi'

module Wafer
  class Error < StandardError; end

  DEFAULT_SETTINGS = {
      "http" => {
        "port" => 2072,
      },
      "authServer" => {
          "serverIP" => "0.0.0.0",
          "serverAuthPort" => 2070,
          "serverCtlPort" => 2071,
          "selectTimeout" => 1.0,
      }

  }

  class Server
    attr_reader :repo
    attr_reader :settings

    def initialize(repo:, settings: {})
      @repo = repo

      @settings = {
        "http" => DEFAULT_SETTINGS["http"].dup,
        "authServer" => DEFAULT_SETTINGS["authServer"].dup,
      }
      @settings.merge! settings

      @read_sockets = []
      @err_sockets = []
      @socket_types = {}
      @seq_numbers = {}
    end

    def log(message)
      pre = "[#{Time.now}] "
      puts pre + message
    end

    def conn_connect(parent_socket, conn_type)
      STDERR.puts "Connected! Socket type #{conn_type.inspect} on parent socket"
      client = parent_socket.accept
      @socket_types[client] = conn_type
      @read_sockets.push(client)
      @err_sockets.push(client)
      return client
    end

    def conn_disconnect(conn)
      @read_sockets -= [ conn ]
      @err_sockets -= [ conn ]
      @socket_types.delete(conn)
      @seq_numbers.delete(conn)
      begin
        log("Closing connection of type #{@socket_types[conn].inspect}...")
        errant_conn.close
      rescue
        log("Closing connection of type #{@socket_types[conn].inspect}... (But got an error, failing - this is common.)")
      end
    end

    def send_error(conn, message)
      seq = @seq_numbers[conn]
      log("Error on conn (#{seq}): #{message}")
      conn.write "#{seq} ERR #{message}\n"
    end

    def send_ok(conn, message)
      conn.write "#{@seq_numbers[conn]} OK #{message}\n"
    end

    def event_loop
      ctl_server = TCPServer.new @settings["authServer"]["serverIP"], @settings["authServer"]["serverCtlPort"]
      auth_server = TCPServer.new @settings["authServer"]["serverIP"], @settings["authServer"]["serverAuthPort"]

      loop do
        sleep 0.1
        readable, _, errorable, = IO.select (@read_sockets + [ctl_server, auth_server]), [], @err_sockets + [], @settings["authServer"]["selectTimeout"]

        readable ||= []
        errorable ||= []

        # Accept new connections if parent sockets are readable
        conn_connect(ctl_server, :ctl) if readable.include?(ctl_server)
        conn_connect(auth_server, :auth) if readable.include?(auth_server)
        readable -= [ctl_server, auth_server]

        # Close connections on error
        errorable.each { |errant_conn| conn_disconnect(errant_conn) }

        (readable - errorable).each do |conn|
          data = conn.read
          if !data || data == ""
            STDERR.puts "Done, disconnecting!"
            conn_disconnect(conn)
            next
          end
          STDERR.puts "Successful read: #{data.inspect}"
          parts = data.chomp.strip.split(" ").map { |part| CGI::unescape(part) }
          next if parts == []  # No-op

          STDERR.puts "Successful parse: #{parts.inspect}"

          case @socket_types[conn]
          when :ctl
            ctl_respond(conn, parts)
          when :auth
            auth_respond(conn, parts)
          else
            log("Wrong socket type #{@socket_types[conn].inspect} for connection!")
            conn_disconnect(conn)
          end
        end
      end
    end
  end
end

require_relative "wafer/json_repo"
require_relative "wafer/auth_server"
require_relative "wafer/ctl_server"
