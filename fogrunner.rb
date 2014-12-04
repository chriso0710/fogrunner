require 'fog'
require 'ap'
require 'trollop'
require 'colorize'
require 'parseconfig'
require 'logger'

VERSION             = "0.8.0"
DEFAULT_REGIONS     = "eu-west-1 us-east-1 ap-southeast-1 ap-northeast-1"
DEFAULT_SCALETYPE   = "m1.large"
DEFAULT_SECTION     = "default"
SUB_COMMANDS        = {"regions" => :c_regions, "status" => :c_status, "s3status" => :c_s3status, "snapshots" => :c_snapshots, "scale" => :c_scale, "dns" => :c_dns}

$stdout.sync = true

class FogRunner
    CONFIGPATH = ENV['HOME']+'/.aws/config'

    def initialize(profile, regions = DEFAULT_REGIONS, verbose = FALSE, debug = FALSE)
   	@configsection = profile
        @verbose = verbose

        @logger = Logger.new($stdout)
        debug ? @logger.level = Logger::DEBUG : @logger.level = Logger::FATAL
        @logger.info "Connecting to AWS"
        @logger.ap credentials
        
        @compute = {}
        begin
            regions.split(' ').each do |region|
                @compute.merge!(region => Fog::Compute.new(credentials.merge({:region => region})))
            end
        rescue ArgumentError
            @logger.fatal "Error connecting to AWS"
        else
            @logger.info "Connected successfully"
        end

        @logger.ap @compute
    end

    def credentials
        c = { :provider => 'AWS' }
        begin
            config = ParseConfig.new(CONFIGPATH)
        rescue Errno::EACCES
            config = nil
        end
        if @configsection && config && config[@configsection] then
            c.merge!( {
                :aws_access_key_id        => config[@configsection]['aws_access_key_id'],
                :aws_secret_access_key    => config[@configsection]['aws_secret_access_key'],
            } )
        elsif
            c.merge!( {
                :aws_access_key_id        => ENV['AWS_ACCESS_KEY'],
                :aws_secret_access_key    => ENV['AWS_SECRET_KEY'],
            } )
        end
        c
    end

    def find_server_by_name(name)
        allservers = []
        @compute.each_value do |r| 
            r.servers.select {|s| allservers << s}
        end
        allservers.select {|s| s.tags["Name"].eql?(name)}.first
    end

    def output_state(state)
        case state
            when "running"
                color = :green  
            when "stopped"
                color = :red
            else
                color = :cyan       
        end
        state.colorize(color)
    end

    def output_server(server)
        printf "%-10s %-15s: %-10s %-10s %-15s", server.id, server.tags["Name"], output_state(server.state), server.flavor_id, server.availability_zone, server.dns_name, server.public_ip_address
        printf " DNS/IP: %s (%s)", server.dns_name, server.public_ip_address if server.dns_name
        printf " Tags: %s", server.tags if @verbose
        printf("\n")
    end

    def delete_snapshot(region, s)
        begin
            region.delete_snapshot(s.id)
            puts "   #{s.id} #{s.description} #{s.created_at} deleted".colorize(:red)
        rescue Exception => e
            @logger.fatal e.message
        end
    end

    def snapcurrentyear?(s)
        s.created_at.year == DateTime.now.year
    end

    def snaplastyear?(s)
        s.created_at.year == DateTime.now.year - 1
    end

    def snap1or15currentyear?(s)
        (s.created_at.day == 1 || s.created_at.day == 15) && snapcurrentyear?(s)
    end

    def snaplastmonth?(s)
        if DateTime.now.month == 1 
            mcm = 12
            mcy = DateTime.now.year - 1
        else
            mcm = DateTime.now.month - 1
            mcy = DateTime.now.year
        end
        s.created_at.month == mcm && s.created_at.year == mcy 
    end

    def snapcurrentmonth?(s)
        s.created_at.month == DateTime.now.month && s.created_at.year == DateTime.now.year 
    end

    def snapshots_normal(region, serversnaps, server, limitserver, remove)
        # show and optionally delete snapshots with special logic (see README)
        # group by year and month, make hash
        # http://stackoverflow.com/questions/5639921/group-a-ruby-array-of-dates-by-month-and-year-into-a-hash
        hash_by_year = Hash[
            serversnaps.group_by{|s| s.created_at.year}.map{|y, items|
                [y, items.group_by{|s| s.created_at.month}]
            }
        ]
        #ap hash_by_year
        hash_by_year.each do |y,h|
            puts "   Year #{y}:"
            h.each do |m,a|
                puts "   Month #{m}: #{a.size} snapshots from #{a.first.created_at.to_date} to #{a.last.created_at.to_date}, Total size #{a.map(&:volume_size).inject(0, :+)} GB"
                last = a.last
                to_delete = a.select do |s| 
                    !(s.created_at.day == last.created_at.day && (snapcurrentyear?(s) || snaplastyear?(s))) && # not the last in current or last year 
                    !(snapcurrentmonth?(s)) && # not current month
                    !(snaplastmonth?(s)) && # not last month
                    !(snap1or15currentyear?(s)) # not first or 15. day in current year
                end 
                if to_delete.any? 
                    if limitserver
                        if server.tags["Name"] == limitserver.tags["Name"]
                            puts "   Month #{m}: #{to_delete.size} snapshots to delete from #{to_delete.first.created_at.to_date} to #{to_delete.last.created_at.to_date}".colorize(:red) 
                            to_delete.each{|s| delete_snapshot(region, s) if remove}
                        end
                    else
                        puts "   Month #{m}: #{to_delete.size} snapshots to delete from #{to_delete.first.created_at.to_date} to #{to_delete.last.created_at.to_date}".colorize(:red) 
                        to_delete.each{|s| delete_snapshot(region, s) if remove}
                    end
                end
            end
        end
    end

    def snapshots_full(region, serversnaps, server, limitserver, remove)
        # show and optionally delete all snapshots but the latest (see README)
        a = serversnaps
        if a.any?
            puts "   #{a.size} snapshots from #{a.first.created_at.to_date} to #{a.last.created_at.to_date}, Total size #{a.map(&:volume_size).inject(0, :+)} GB"
            last = a.last
            to_delete = a.select do |s| 
                (s.created_at != last.created_at)
            end 
            if to_delete.any? 
                if limitserver
                    if server.tags["Name"] == limitserver.tags["Name"]
                        puts "   #{to_delete.size} snapshots to delete from #{to_delete.first.created_at.to_date} to #{to_delete.last.created_at.to_date}".colorize(:red) 
                        to_delete.each{|s| delete_snapshot(region, s) if remove}
                    end
                else
                    puts "   #{to_delete.size} snapshots to delete from #{to_delete.first.created_at.to_date} to #{to_delete.last.created_at.to_date}".colorize(:red) 
                    to_delete.each{|s| delete_snapshot(region, s) if remove}
                end
            end
        end
    end

    def snapshots(servername, remove = FALSE, full = FALSE)
        limitserver = find_server_by_name(servername)
        @compute.each_value do |region| 
            puts "#{region.snapshots.length} snapshots in region #{region.region}".colorize(:blue)
            snapshots = region.snapshots.all.sort_by {|s| s.created_at}
            region.servers.select do |server|
                # filter snapshots by servername
                serversnaps = snapshots.select {|s| s.description && s.description.include?(server.tags["Name"])}
                puts "#{serversnaps.length} snapshots for server #{server.tags["Name"]}".colorize(:green)
                full ? snapshots_full(region, serversnaps, server, limitserver, remove) : snapshots_normal(region, serversnaps, server, limitserver, remove)
                #serversnaps.each do |s|
                    #printf "%s %s %-10s\n", s.description, s.created_at, s.volume_size
                #end
            end
        end
    end

    def status(servername = nil)
        if servername then
            server = find_server_by_name(servername)
            output_server(server) if server
        else
            @compute.each_value do |region| 
                puts "#{region.servers.length} servers in region #{region.region}".colorize(:blue) if @verbose
                region.servers.select do |s|
                    output_server(s)
                end
                @logger.ap region.describe_addresses.body["addressesSet"]
            end
        end
    end

    def s3status
        begin
            storage = Fog::Storage.new(credentials)
        rescue ArgumentError
            @logger.fatal "Error connecting to AWS"
        end

        if storage then
            storage.directories.each do |dir|
                @logger.ap dir
                puts "#{dir.key} (#{dir.location})"
            end
        end
    end

    def dns(domain, oldip, newip, modify = FALSE)
        begin
            # create a DNS connection
            dns = Fog::DNS.new(credentials)
        rescue ArgumentError
            @logger.fatal "Error connecting to AWS"
        end

        if dns then
            if domain
                zones = dns.zones.select {|e| e.domain.match(Regexp.new domain)}
            else
                zones = dns.zones
            end
            zones.each do |z|
                puts "#{z.domain}".colorize(:blue) if @verbose
                if oldip
                    records = z.records.all!.select {|e| e.value.join(" ").include? oldip}
                else
                    records = z.records.all!
                end
                records.each do |r|
                    @verbose ? puts("#{r.name} #{r.type} #{r.value.join(' ')}") : puts("#{r.name.chomp('.')}")
                    if oldip && newip && r.type == "A"
                        if modify 
                            r.modify({:value => [newip]})
                            puts "changed #{r.name} #{r.type} from #{oldip} to #{r.value.join(" ")}".colorize(:red)
                            @logger.ap r
                        else
                            puts "would change #{r.name} #{r.type} from #{r.value.join(" ")} to #{newip}".colorize(:red)
                        end
                    end
                end
            end
        end
    end

    def find_server_region(server)
        @compute[server.availability_zone.chop]
    end

    def scale(servername, type, noaddress = FALSE, nostart = FALSE)
        server = find_server_by_name(servername)
        if server && server.flavor_id != type then
            output_server(server)
            @logger.ap server
            # get server region
            serverregion = find_server_region(server)
            # check state
            case server.state 
                when "running"
                    saveip = server.public_ip_address
                    print "Saving IP."
                    print "Stopping."
                    server.stop
                    server.wait_for { print "."; state == "stopped" }
                when "stopped"  
                    # do nothing        
                else
                    # do nothing
            end
            print "Modifying."
            serverregion.modify_instance_attribute server.id, {"InstanceType.Value" => type}
            if !nostart then
                print "Starting."
                server.start
                server.wait_for { print "."; ready? }
                if saveip && !noaddress then
                    print "Addressing."
                    begin
                        serverregion.associate_address server.id, saveip
                    rescue Exception => e
                        puts
                        @logger.fatal e.message
                    end
                end
            end
            puts
            server.reload
            output_server(server)
        end
    end

    def regions
        if @compute.any? then
            aws = @compute.first[1]
            regions = aws.describe_regions.body["regionInfo"].map {|region| region["regionName"]}
            regions.each { |r| puts "#{r}" }
        end
    end

end




opts = Trollop::options do
    version "fogrunner " + VERSION
    banner <<-EOS
Fogrunner - AWS Simple CLI
(AWS credentials via environment variables AWS_*_KEY or ~/.aws/config)

Usage:
    fogrunner [global options] [command] [command options]

where [command] is one of:
    status: Show EC2 status
    s3status: Show S3 status
    regions: Show all regions
    scale: Scale EC2 instance, set new instance type
    dns: Show DNS records, set new IP for A records
    snapshots: Show and delete snapshots

where [options] are:
EOS
    opt :verb, "Verbose output"
    opt :debug, "More verbose debug output"
    opt :region, "Set AWS regions", :type => :string, :default => DEFAULT_REGIONS
    opt :profile, "Set profile from ~/.aws/config", :type => :string, :default => DEFAULT_SECTION
    opt :dryrun, "Mock & simulate"
    stop_on SUB_COMMANDS.keys
end

cmd = ARGV.shift # get the subcommand
cmd_opts = case SUB_COMMANDS[cmd]
    when :c_status 
            Trollop::options do
            opt :name, "Find server instance by name tag", :type => :string
        end
    when :c_s3status # no options
    when :c_dns 
        Trollop::options do
            opt :domain, "Find zone by domainname regex", :type => :string
            opt :ip, "Find record by ip", :type => :string
            opt :newip, "Set new IP for A record", :type => :string
            opt :modify, "Make modification"
        end
    when :c_regions # no options
    when :c_snapshots 
        Trollop::options do
            opt :name, "Find server instance by name tag", :type => :string
            opt :remove, "Delete old snapshots"
            opt :full, "Alternative delete method: delete all but last snapshot"
        end
    when :c_scale 
        Trollop::options do
            opt :name, "Find server instance by name tag", :type => :string
            opt :type, "Set instance type, Examples: t1.micro, m1.small, m1.medium, m1.large, m1.xlarge, m3.2xlarge", :type => :string, :default => DEFAULT_SCALETYPE
            opt :noaddress, "Do not try to associate IP"
            opt :nostart, "Do not start instance afterwards"
        end
    else
        Trollop::die "unknown command #{cmd.inspect}"
end

ap opts if opts[:debug]
ap cmd_opts if opts[:debug]

Fog.mock! if opts[:dryrun]

aws = FogRunner.new(opts[:profile], opts[:region], opts[:verb], opts[:debug])

case SUB_COMMANDS[cmd]
    when :c_status
        aws.status(cmd_opts[:name])
    when :c_s3status
        aws.s3status
    when :c_dns
        aws.dns(cmd_opts[:domain], cmd_opts[:ip], cmd_opts[:newip], cmd_opts[:modify])
    when :c_regions
        aws.regions
    when :c_snapshots
        aws.snapshots(cmd_opts[:name], cmd_opts[:remove], cmd_opts[:full])
    when :c_scale
        Trollop::die :name, "must exist" unless cmd_opts[:name]
        aws.scale(cmd_opts[:name], cmd_opts[:type], cmd_opts[:noaddress], cmd_opts[:nostart])
end
