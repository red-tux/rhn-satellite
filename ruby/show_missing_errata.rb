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

# Andrew Nelson  anelson@redhat.com 2013-08-20

# Show Missing Errata
# Script to show which errata are missing from clone channels.

require "csv"
require "pp"
require "yaml"

def read_csv(filename)
  csv_data=CSV.open(filename,"r")
  header=csv_data.shift

  retval=[]

  while !(row=csv_data.shift).empty?
    retval<<Hash[header.zip(row)]
  end

  retval
end

def get_report(report)
  csv_data=[]
  IO.popen("/usr/bin/spacewalk-report #{report}") do |spwrpt|
    spwrpt.each do |line|
      csv_data<<CSV.parse_line(line)
    end
  end
  header = csv_data.shift
  
  retval=[]
  while row=csv_data.shift
    retval<<Hash[header.zip(row)]
  end

  retval
end
  

env_channels = YAML.load_file("channel-layout.yaml")    

#errata_list_all=read_csv("errata-list-all")

errata_list_all = Hash.new do |hash,key|
  hash[key]={}
end

#generate a hash of all errata by advisory
get_report("errata-list-all").each do |h|
  tmp = h.select { |k,v| !([k]-["advisory"]).empty? }
  errata_list_all[h["advisory"]] = Hash[tmp]
end

#Hash.new([]) did not want to work for some reason
#So we do it the long way.
errata_by_channels = Hash.new do |hash,key|
  hash[key]=[]
end

#errata_in_channels[channel_label]=>[advisory]
errata_in_channels = Hash.new do |hash,key|
  hash[key]=[]
end

#errata_by_numbers[index]=>[errata]
#index is YYYY:NNNN
#errata is RH??-YYYY:NNNN and/or CLA-YYYY:NNNN
errata_by_numbers = Hash.new do |hash,key|
  hash[key]=[]
end

get_report("errata-channels").each do |h|
  errata_by_channels[h["advisory"]]<<h["channel_label"]
  errata_in_channels[h["channel_label"]]<<h["advisory"]
  /([^-]+)-(\d+):(\d+)/ =~ h["advisory"]
  type = Regexp.last_match(1)
  year = Regexp.last_match(2).to_i
  num = Regexp.last_match(3).to_i
  index="#{year}:#{num}"
  errata_by_numbers[index]<<h["advisory"]
end

errata_by_numbers= errata_by_numbers.map do |k,v|
  [k,v.uniq!]
end
errata_by_numbers=Hash[errata_by_numbers]

errata_by_numbers.delete_if do |k,v|
  v.nil?
end

channels = Hash.new do |hash,key|
  hash[key]={}
end

get_report("channels").each do |h|
  tmp = h.select { |k,v| !([k]-["channel_label"]).empty? }
  channels[h["channel_label"]]=Hash[tmp]
end

# Generate a list of errata in the form of type,year,num
# errata is a hash storing these values, the top level key is type
# type contains keys for each year
# year is a key for an array holding the erratun numbers

errata = Hash.new do |hash,key|
  hash[key] = Hash.new do |h,k|
    h[k] = Hash.new do |h1,k1|
      h1[k1]=[]
    end
  end
end

#errata is in the format of [type][year]=>[num]

errata_by_channels.each { |k,v|
  /([^-]+)-(\d+):(\d+)/ =~ k
  type = Regexp.last_match(1)
#  type = type=="CLA" ? "Clone" : "RedHat"
  year = Regexp.last_match(2).to_i
  num = Regexp.last_match(3).to_i
  errata[type][year][num]=v
}

rh_errata=errata.select do |k,v|
  !([k]-["CLA"]).empty?  
end
rh_errata=Hash[rh_errata]

cl_errata=errata["CLA"]

rh_errata.each do |type,years|
  cl_errata.each_key do |year|
    cl_errata[year].each_key do |num|
      rh_errata[type][year].delete(num)
    end
  end
  rh_errata[type].delete_if {|k,v| v.nil? || v.empty? }
end
rh_errata.delete_if {|k,v| v.nil? || v.empty? }


errata_not_installed=[]
rh_errata.each do |type,years|
  years.each do |year,num|
    num.each_key do |n|
      errata_not_installed<<type+"-"+year.to_s+":"+n.to_s
    end
  end
end


puts "Errata missing from all channels:"
errata_not_installed.each do |erratum|
  puts "#{erratum} : #{errata_list_all[erratum]["synopsis"]} : "\
       "#{errata_by_channels[erratum].join(", ")}"
end

puts
puts "Errata missing per channel"
puts

env_channels.delete_if do |k,v|
  v["upstream"]==:rhn
end

#Commented code is a framework for showing parent/child only
#
#child_channels=env_channels.map do |k,v|
#  v["children"]
#end.flatten!.compact!
#
#parent_channels=env_channels.clone
#parent_channels.delete_if do |k,v|
#  ([k]-child_channels).empty?
#end
#
#parent_channels.each do |channel,v|
env_channels.each do |channel,v|
  upstream_errata=errata_in_channels[v["upstream"]].map do  |errata|
    /([^-]+)-(\d+):(\d+)/ =~ errata
    type = Regexp.last_match(1)
    year = Regexp.last_match(2).to_i
    num = Regexp.last_match(3).to_i
    ["#{year}:#{num}",errata]
  end
  upstream_errata=Hash[upstream_errata]

  chan_errata=errata_in_channels[channel].map do |errata|
    /([^-]+)-(\d+):(\d+)/ =~ errata
    type = Regexp.last_match(1)
    year = Regexp.last_match(2).to_i
    num = Regexp.last_match(3).to_i
    "#{year}:#{num}"
  end

  upstream_errata.delete_if do |num,errata|
    ([num]-chan_errata).empty?
  end

  if !upstream_errata.empty?
    puts "Errata missing from #{channel} which comes from #{v["upstream"]}"
    upstream_errata.each do |k,v| 
      puts "#{v} : #{errata_list_all[v]["synopsis"]}"
    end
    puts
  end
end
    
    
