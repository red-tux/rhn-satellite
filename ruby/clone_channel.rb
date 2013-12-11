#!/usr/bin/ruby

#
#  Copyright Red Hat, Inc. 2012
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

# pull_packages.rb
# Script to pull rpm packages from an RHN Satellite server and create
# YUM repositories.
# Andrew Nelson  anelson@redhat.com 2-22-12


require 'satellite'
require 'optparse'
require 'yaml'
require 'pp'

EXEC_STR=$0

def parseoptions(showhelp=false)
  options={}

  optparse=OptionParser.new do |opts|
    opts.banner = "#{EXEC_STR} [options] WORKFILE"
    opts.separator "Channel download script"
    
    options[:help]=false
    opts.on("-?","--help","Show this help information") do
      options[:help]=true
    end

    options[:host]="localhost"
    opts.on('-h HOSTNAME', 'Satellite Server to connect to') do |host|
      options[:host] = host
    end

    opts.on("-u USER", "Username to connect with") do |user|
      options[:user]=user
    end

    options[:list]=false
    opts.on("-l","List available channels") do 
      options[:list]=true
    end

    options[:delete]=false
    opts.on("-d","Delete destination channels if they already exist") do
      options[:delete]=true
    end

    options[:yes]=false
    opts.on("-y","Answer Yes to all questions") do
      options[:yes]=true
    end

    options[:timeout]=300
    opts.on("-t TIMEOUT", "Timeout in seconds, default: #{options[:timeout]}", Integer) do |timeout|
      options[:timeout]=timeout
    end

    opts.separator ""
    opts.separator "The workfile uses YAML Syntax: http://yaml.org/spec/1.0/"
    opts.separator "Each channel is defined within a sequence.  Each channel"
    opts.separator "must at a minimum contain source, name and label."
    opts.separator "Other valid options: name, label, summary, parent_label,"
    opts.separator "arch_label, gpg_url, gpg_id, gpg_fingerprint, description"
    opts.separator "All optional options not used are automatically populated"
    opts.separator "from the values from the source channel."
    opts.separator "The option parent_label is used to create a clone as the"
    opts.separator "child of an existing channel."
    opts.separator ""
    opts.separator "Example YAML work file:"
    opts.separator "- source: rhel-x86_64-server-6"
    opts.separator "  name: Clone of RHEL 6 x86_64"
    opts.separator "  label: clone-rhel6-x86_64"
    opts.separator ""
    opts.separator "- source: rhn-tools-rhel-x86_64-server-6"
    opts.separator "  name: Clone of RHN Tools for RHEL 6 x86_64"
    opts.separator "  label: clone-rhn-tools-rhel6-x86_64"
    opts.separator "  parent_label: clone-rhel6-x86_64"
    opts.separator ""
  end

  begin
    optparse.parse! unless showhelp
  rescue OptionParser::InvalidOption,OptionParser::MissingArgument => e
    puts "*** #{e.message}\n\n"
    puts optparse
    exit 1
  end

  if options[:help] || showhelp
    puts optparse
    exit 1
  end

  if options[:user].nil? && !options[:help]
    puts "*** Option -u USER is required.\n\n"
    puts optparse
    exit 1
  end

  if options[:host].empty?
    puts "*** Option -h may not be blank.\n\n"
    puts optparse
    exit 1
  end

  options
end

def wait(seconds,indent=0)
  puts "%sWaiting #{seconds} seconds" % (" "*indent)
  sleep(seconds)
end

def retry_http_error(error_nums=[],retries=5,delay=30,&block)
  raise "At least HTTP error number required" if error_nums.empty?

  total_retries=retries

  begin
    yield
  rescue RuntimeError => e
      if retries<1
        puts "** Maximum retries reached, exiting"
        exit(1)
      end

      found=false
      error_nums.each {|num|
        found=e.message =~ /HTTP-Error: (#{num})/
        break if found
      }
      if found
        puts "** A #{$1} error was received from the RHN Satellite Server"
        puts "** #{retries} retries left"
        delay_val=(delay*total_retries/retries/3)+(delay*2/3)
        wait(delay_val,2)
        retries-=1
        retry
      else
        raise e
      end
    end
end

#show_channels(Satelite Server)
#Prints a list of available channels to the screen by Channel Label.
def show_channels(sat)
  channels=sat.call_async("channel.listSoftwareChannels")
  chan_hash={}
  channels.each do |chan|
    chan_hash[chan["label"]]=get_children(sat,chan["label"]) if chan["parent_label"].empty?
  end
  chan_hash.keys.sort.each do |k|
    puts " #{k}"
    chan_hash[k].sort.each do |v|
      puts "   #{v}"
    end
  end
end

#verify_channel(Satellite Server, Channel Label)
#returns true/false if the Channel Label passed in is a valid Channel
#Label for one of the channels on the Satellite Server.
def verify_channel(sat,channel)
  channels=sat.call_async("channel.listSoftwareChannels")
  found=false
  channels.each do |chan|
    if chan["label"]==channel
      return true
    end
  end
  false
end

#get_children(Satellite Server, Channel Label)
#Returns an array of child channel labels.  Returns an empty array if no
#children.
def get_children(sat,channel)
  sat.call_async("channel.software.listChildren",channel).map {|i| i["label"] }
end

def get_channel_details(sat,channel,recover=false)
  begin
    source=sat.call_async("channel.software.getDetails",channel)
  rescue XMLRPC::FaultException => e
    if e.message =~ /No such channel/
      return {} unless recover
      puts "\n*** Unknown Channel: #{channel} ***" 
    else
      puts "\n*** Unknown error: #{e.message}    (line: #{__LINE__})***"
    end #if e.message
    exit 1
  end  #begin
end

def delete_channel(sat,channel)
  if sat.call_async("channel.software.delete",channel)!=1
    puts "There was an error deleting #{channel}, exiting"
    exit 1
  end
  wait(30,2)
end

def clone_errata(sat,source,dest,options)
  puts " Merging Errata"

  retry_http_error [503] do
    result=sat.call_async("channel.software.mergeErrata",source,dest)
    puts "  #{result.length} Errata merged"
  end

  puts "  Merging all remaining packages."
  retry_http_error [503]  do
    result=sat.call_async("channel.software.mergePackages",source,dest)
    puts "  #{result.length} Packages merged"
  end
end

def clone_channel(sat,channel,options)

  retries=5

  delete_chan = options[:yes]
  retry_http_error [503]  do
    if !get_channel_details(sat,channel["label"]).empty?
      puts "Target channel #{channel["label"]} found!"

      if !options[:delete]
        puts "  \"-d\" option not used, skipping Channel delete"
      else
        puts "Delete #{channel["label"]} and all of it's children? [y/N]?"
        if delete_chan
          puts "Y  (Auto answer)"
        else
          answer=STDIN.gets.chomp
          delete_chan = answer.upcase=="Y"
        end

        if !delete_chan
          puts "Exiting per user request"
          exit 1
        end

        get_children(sat, channel["label"]).each { |child|
          puts "  Deleting child channel #{child}"
          delete_channel(sat, child)
          puts "  done"
        }

        puts "  Deleting channel #{channel["label"]}"
        delete_channel(sat, channel["label"])
        puts "  done"
      end
    end
  end


  #setup the valid list of keys for clone creation
  valid_clone_items=["name", "label", "summary", "parent_label", "arch_label",
      "gpg_url", "gpg_id", "gpg_fingerprint", "description"]

  #verify the data from the work file is valid
  invalid=Hash[*channel.select {|k,v|
    !(valid_clone_items + ["source"]).include?(k)
  }.flatten]

  if !invalid.empty?
    invalid.each {|k,v|
      puts "Invalid channel item: #{k}"
    }
    exit 1
  end 

  #verify the source channel exists and retrieve data
  puts "Verifying and retrieving data from source channel"
  source=nil
  retry_http_error([503],2) do
    source=get_channel_details(sat,channel["source"])
  end

  #remap some of the keys returned
  replace_list = { "parent_channel_label" => "parent_label",
    "arch_name" => "arch_label", "gpg_key_url" => "gpg_url",
    "gpg_key_id" => "gpg_id", "gpg_key_fp" => "gpg_fingerprint"}

  replace_list.each do |k,v|
    source[v]=source[k]
    source.delete(k)
  end

  #setup the destination hash
  dest={}

  valid_clone_items.each do |key|
    dest[key]=source[key]
  end
  
  dest.merge!(channel)
  dest.delete_if do |k,v|
    !valid_clone_items.include?(k) || v.empty?
  end

  puts "  Performing clone"
  retry_http_error [503] do

    #Check to see if the Channel has already been created.
    #An Exception will be raised if it has not.
    exists=true
    begin
      sat.call_async("channel.software.getDetails",dest["label"])
    rescue XMLRPC::FaultException => e
      if e.message =~ /No such channel/
        exists=false
      else
        raise e
      end
    end

    if exists
      puts "  Channel #{dest["label"]} found skipping create"
    else
      chanid=sat.call_async("channel.software.clone",channel["source"],dest,true)

      puts "Channel created with channelid of: #{chanid}"
      wait(30,2)
    end
  end

  clone_errata(sat,channel["source"],channel["label"],options)

end


def clone_work_loop(sat,workfile,options)
  worklist=YAML::load(File.open(workfile))

  worklist.each do |channel|
    if channel["delay_before"]
      puts "Delay directive found, waiting #{channel["delay_before"]} seconds before proceeding"
      wait(channel["delay_before"],2)
      channel.delete("delay_before")
    end
    puts
    puts "Cloning: %s" % channel["source"]
    puts "  Destination: %s" % channel["label"]
    puts "  Parent Channel: %s"%channel["parent"] unless channel["parent"].nil?
    clone_channel(sat,channel,options)
  end
end


###########################
# "Main"
###########################
options=parseoptions

if ARGV.length==0 && !options[:list]
  puts "No workfile passed in, showing channel list"
  options[:list]=true
elsif ARGV.length>1
  puts "Only one workfile may be specified"
  parseoptions(true)
end

workfile=ARGV[0]

sat=Satellite.new(options[:host])
sat.cache_session=true
sat.login(options[:user])

sat.timeout=options[:timeout]

begin
  if options[:list]
    show_channels(sat)
    exit 0
  end

  clone_work_loop(sat,workfile,options)
rescue RuntimeError => e
  if e.message =~ /HTTP-Error: 500/
    puts "** An HTTP error code of 500 was received from the RHN Satellite Server"
    puts "** Check the work file to ensure channel labels and names are not used twice."
  else
    raise e
  end
rescue XMLRPC::FaultException => e
  if e.message =~/ORA-00060: deadlock detected/
    puts "** A deadlock was detected in the API"
    puts "** Often this will self-correct within a few minutes"
    puts "** Consider breaking work file into smaller pieces or adding a"
    puts "** \"delay_before\" directive to the work file."
    puts "** Exmple:"
    puts "- source: rhel-i386-server-6"
    puts "  name: Clone of RHEL 6 for i386"
    puts "  label: clone-rhel6-i386"
    puts "  delay_before: 120"
  else
    raise e
  end
rescue Timeout::Error
  puts
  puts "** A connection timeout error was received"
  puts "** Retry using the -t option with a value greater than #{options[:timeout]}"
end
