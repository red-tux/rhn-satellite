#!/usr/bin/ruby

#
#  Copyright Red Hat, Inc. 2011
#
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU General Public License as published by the
#  Free Software Foundation; either version 2, or (at your option) any
#  later version.
#
#  This program is distributed in the hope that it will be useful, but
#  WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#  General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; see the file COPYING.  If not, write to the
#  Free Software Foundation, Inc.,  675 Mass Ave, Cambridge,
#  MA 02139, USA.
#

# Ruby Wrapper for RHN Satellite
# Andrew Nelson  anelson@redhat.com  2-9-12
# Example usage:
#  sat=Satellite.new
#  sat.login("user")
#  p sat.call("channel.listAllChannels")

require 'xmlrpc/client'
require 'digest'

class Satellite < XMLRPC::Client

  class InvalidFunctionCall < XMLRPC::FaultException
  end

  attr_accessor :cache_session
  def initialize(host="localhost",path="/rpc/api")
    #new(host=nil, path=nil, port=nil, proxy_host=nil, proxy_port=nil, user=nil, password=nil, use_ssl=nil, timeout=nil)
    super(host,path,nil,nil,nil,nil,nil,true)
    @host=host
    @user=nil
    @session=nil
    @cache_session=false
    @session_file_override=nil

    #set the http portion to not verify SSL certs
    super.instance_variable_get(:@http).
          instance_variable_set(:@verify_mode,OpenSSL::SSL::VERIFY_NONE)

  end

  def session_file
    if @session_file_override.nil?
      "~/rhnsat-#{@host}-#{@user}-session"
    else
      @session_file_override
    end
  end

  def session_file=(path)
    @session_file_override=path
  end

  alias :call_super :call

  def call(method, *params)
    begin
      if @session.nil?
        if params.empty?
          call_super(method)
        else
          call_super(method,*params)
        end
      else
        if params.empty?
          call_super(method,@session)
        else
          call_super(method, @session, *params)
        end
      end
    rescue XMLRPC::FaultException => e
      if e.message =~ /The specified handler cannot be found/
        raise InvalidFunctionCall.new(e.faultCode,"Invalid function call: #{method}")
      else
        raise e
      end
    end
  end

  alias :call_async_super :call_async

  def call_async(method, *params)
    begin
      if @session.nil?
        if params.empty?
          call_async_super(method)
        else
          call_async_super(method,*params)
        end
      else
        if params.empty?
          call_async_super(method,@session)
        else
          call_async_super(method, @session, *params)
        end
      end
    rescue XMLRPC::FaultException => e
      if e.message =~ /The specified handler cannot be found/
        raise InvalidFunctionCall.new(e.faultCode,"Invalid function call: #{method}")
      else
        raise e
      end
    end
  end

  def get_password(prompt="Password: ")
    #It would be nice if we could use the RubyGems Highline package, but
    #it's not included in RHEL so we need to do this old school
    begin
      system "stty -echo"
      printf prompt
      password=STDIN.gets.chomp
    ensure
      #Ensure a newline character and the echo are always turned on 
      #irrespective of any errors seen.
      puts
      system "stty echo"
    end
    password
  end
  
  def login(user,pass=nil)
    @user=user
    path=File.expand_path(session_file)
    if @cache_session
      begin
        session=File.open(path,"r").gets
        call_super("org.listOrgs",session)
      rescue => e
        puts "Valid Session Cache not found."
        session=nil
      end
      @session=session
    end
    if @session.nil?
      pass=get_password("Password for #{user}: ") if pass.nil?
      @session=call_super("auth.login",user,pass)
    end
    if @cache_session
      File.open(path,'w') {|f| 
        f.puts(@session)
      }
    end
  end

  def get_package(pkg_id,path,options={})
    options[:count_divisor]||=100
    options[:show_dot]=options[:show_dot].nil? ? true : options[:show_dot]
    options[:overwrite]=options[:overwrite].nil? ? true : options[:overwrite]

    pkg_info=nil

    if !options[:overwrite] || options[:verify]
      pkg_info=call("packages.getDetails",pkg_id)
    end

    if !options[:overwrite] && File.exists?(path)
      if File.size(path)!=pkg_info["size"].to_i
        printf "Incorrect size, redownloading "
        File.delete(path)
      else
        puts "Skipping"
        return true
      end
    end

    uri=URI.parse(call("packages.getPackageUrl",pkg_id))
    f=File.open(path,"wb")
    finished=false
    Net::HTTP.start(uri.host,uri.port) do |http| 
      begin
        http.request_get(uri.path) do |resp|
          count=0
          resp.read_body do |segment|
            count+=1
            putc "." if (count%options[:count_divisor]==0) && options[:show_dot]
            f.write(segment)
          end
          puts
        end
	finished=true
      ensure
        f.close
	File.delete(path) unless finished
      end
    end
  end
      
end

#Usage Example:

#require 'pp'
#sat=Satellite.new
#sat.cache_session=true
#sat.login(USER)
#pp sat.call("channel.listAllChannels")
