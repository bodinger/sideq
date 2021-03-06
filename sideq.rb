#!/usr/bin/env ruby

require 'optparse'
require 'sidekiq'
require 'sidekiq/api'

RACK_ENV = ENV['RACK_ENV'] || "development"

class Parser
  def self.parse(arguments)
    options = { "host" => "localhost",
                "port" => 6379,
                "db"   => 0 }

    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [options] command [subcommand]\n" <<
                    "\n" <<
                    "Commands and subcommands:\n" <<
                    "stats                    Print sidekiq statistics\n" <<
                    "queue list               List all known queues\n" <<
                    "retry list               List contents of the retry set\n" <<
                    "retry show jid [jid ...] Show details of entrie sin the retry set\n" <<
                    "retry del jid [jid ...]  Delete entries from the retry set\n" <<
                    "retry kill jid [jid ...] Move jobs from the retry set to the dead set\n" <<
                    "retry now jid [jid ...]  Retry jobs in the retry set right now\n" <<
                    "retry clear              Clears all entries in the retry set\n" <<
                    "dead list                List contents of the dead set\n" <<
                    "dead show jid [jid...]   Show details of entries in the dead set\n" <<
                    "dead del jid [jid...]    Delete jobs from the dead set\n" <<
                    "dead now jid [jid...]    Retry jobs from the dead set right now\n" <<
                    "dead clear               Clears all entries of the dead set\n" <<
                    "processes list           Lists all processes known to sidekiq\n" <<
                    "processes quiet          Send the quiet signal to all sidekiq processes\n" <<
                    "processes kill           Send the kill signal to all sidekiq processes\n" <<
                    "processes clean          Clear dead process entries from the process list\n" <<
                    "workers list             List all workers\n"
      opts.separator "\nOptions:\n"

      opts.on("-n redisdb", "--database=redisdb", "Number of the redis database") do |n|
        options["db"] = n.to_i
      end

      opts.on("-h hostname", "--host=hostname", "Hostname of the redis instance") do |n|
        options["host"] = n
      end

      opts.on("-p port", "--port=port", "Portnumber of the redis instance" ) do |n|
        options["port"] = n.to_i
      end

      opts.on( "-u redis_url", "--url", "URL to connect to (redis://host:port/db)" ) do |n|
        options["url"] = n
      end

      opts.on("--help", "Prints this help") do
        puts opts
        exit
      end
    end

    opt_parser.parse!(arguments)
    return options
  end
end

class Stats
  attr_reader :stats, :retry_set, :dead_set

  def initialize
    @stats = Sidekiq::Stats.new
    @retry_set = Sidekiq::RetrySet.new
    @dead_set = Sidekiq::DeadSet.new
  end

  def to_s
    stat_ary = [ "Processed: #{stats.processed}",
                 "Failed: #{stats.failed}",
                 "Scheduled size: #{stats.scheduled_size}",
                 "Retry size: #{stats.retry_size}",
                 "Dead size: #{stats.dead_size}",
                 "Enqueued: #{stats.enqueued}",
                 "Processes: #{stats.processes_size}",
                 "Workers: #{stats.workers_size}",
                 "Default queue latency: #{stats.default_queue_latency}",

                 "Queues: dead:  #{dead_set.size}",
                 "        retry: #{retry_set.size}" ]
    stats.queues.each do |(queue_name, queue_size)|
      stat_ary << "        #{queue_name}: #{queue_size}"
    end

    stat_ary.join( "\n" )
  end
end

class Queues
  attr_reader :retry_set, :dead_set

  def initialize
    @retry_set = Sidekiq::RetrySet.new
    @dead_set = Sidekiq::DeadSet.new
  end

  def to_s
    ary = Sidekiq::Queue.all.each_with_object( [] ) do |queue, memo|
      memo << sprintf( "%-30s %5d (%8.2f s latency), %spaused", 
                      queue.name,
                      queue.size,
                      queue.latency,
                      queue.paused? ? '' : "not " )
    end
    ary << sprintf( "%-30s %5d", "retry", retry_set.size )
    ary << sprintf( "%-30s %5d", "dead", dead_set.size )
    ary.join( "\n" )
  end
end

class Retries
  attr_reader :retry_set

  def initialize
    @retry_set = Sidekiq::RetrySet.new
  end

  def to_s
    retry_set.each_with_object( [ "Retry entries: #{retry_set.size}" ] ) do |job, memo|
      memo << sprintf( "%24s - %19s\n  %-22s - %-37s\n  e: %19s - f: %19s\n  retry (%2d) at %-19s Continue retries?: %s\n  %s\n", 
                        job.jid,
                        job.created_at.strftime( "%F %T" ),
                        job.display_class,
                        job.item["error_class"],
                        job.enqueued_at.strftime( "%F %T" ),
                        Time.at( job.item["failed_at"] ).strftime( "%F %T" ),
                        job.item["retry_count"],
                        job.item["retried_at"] ? Time.at( job.item["retried_at"] ).strftime( "%F %T" ) : "never",
                        job.item["retry"],
                        "#{job.item["error_class"]}: #{job.item["error_message"][0,77-job.item["error_class"].size]}" )
    end.join( "\n" )
  end

  def details( job_ids )
    retry_set.each_with_object( [] ) do |job, memo|
      next unless job_ids.include?( job.jid )
      memo << job_details( job )
    end.join( "\n\n" )
  end

  def delete_entries( job_ids )
    deleted = 0
    job_ids.each do |job_id|
      # TODO: Inefficient in the free(beer) sidekiq version; 
      #       find something more efficient here (sr 2016-04-06)
      job = retry_set.find_job( job_id )
      if job
        job.delete
        puts "#{job_id}: deleted"
        deleted += 1
      else
        puts "#{job_id}: not found"
      end
    end
    puts "Retry Set: Deleted #{deleted} entries"
  end

  def kill_entries( job_ids )
    killed = 0
    job_ids.each do |job_id|
      # TODO: Inefficient in the free(beer) sidekiq version; 
      #       find something more efficient here (sr 2016-04-06)
      job = retry_set.find_job( job_id )
      if job
        begin
          job.kill
          puts "#{job_id}: moved to dead set"
          killed += 1
        rescue
          puts "#{job_id}: failed - #{$!.message}"
        end
      else
        puts "#{job_id}: not found"
      end
    end

    puts "Retry Set: Moved #{killed} entries to Dead Set"
  end

  def retry_entries( job_ids )
    retried = 0
    job_ids.each do |job_id|
      # TODO: Inefficient in the free(beer) sidekiq version; 
      #       find something more efficient here (sr 2016-04-06)
      job = retry_set.find_job( job_id )
      if job
        begin
          job.retry
          puts "#{job_id}: retrying"
          retried += 1
        rescue
          puts "#{job_id}: failed - #{$!.message}"
        end
      else
        puts "#{job_id}: not found"
      end
    end

    puts "Retry Set: Retried #{retried} entries"
  end

  def clear
    puts "Retry Set: Deleted #{retry_set.clear} entries"
  end

  protected
  def job_details( job )
    [ "JobID:         #{job.jid}",
      "Created at:    #{job.created_at.strftime( "%F %T" )}",
      "Enqueued at:   #{job.enqueued_at.strftime( "%F %T")}",
      "Worker class:  #{job.display_class}",
      "Arguments:     #{job.display_args}",
      "Failed at:     #{Time.at( job.item["failed_at"] ).strftime( "%F %T" )}",
      "Retried at:    #{job.item["retried_at"] ? Time.at( job.item["retried_at"] ).strftime( "%F %T" ) : "never"}",
      "Retries:       #{job.item["retry_count"]}",
      "Retry?:        #{job.item["retry"]}",
      "Error Class:   #{job.item["error_class"]}",
      "Error Message: #{job.item["error_message"]}" ].join( "\n" )
  end
end

class Dead
  attr_reader :dead_set

  def initialize
    @dead_set = Sidekiq::DeadSet.new
  end

  def to_s
    dead_set.each_with_object( [ "Dead entries: #{dead_set.size}" ] ) do |job, memo|
      memo << sprintf( "%24s - %19s\n  %-22s - %-37s\n  e: %19s - f: %19s\n  retry (%2d) at %-19s Continue retries?: %s\n  %s\n", 
                       job.jid,
                       job.created_at.strftime( "%F %T" ),
                       job.display_class,
                       job.item["error_class"],
                       job.enqueued_at.strftime( "%F %T" ),
                       Time.at( job.item["failed_at"] ).strftime( "%F %T" ),
                       job.item["retry_count"],
                       job.item["retried_at"] ? Time.at( job.item["retried_at"] ).strftime( "%F %T" ) : "never",
                       job.item["retry"],
                       "#{job.item["error_class"]}: #{job.item["error_message"][0,77-job.item["error_class"].size]}" )
    end.join( "\n" )
  end

  def details( job_ids )
    dead_set.each_with_object( [] ) do |job, memo|
      next unless job_ids.include?( job.jid )
      memo << job_details( job )
    end.join( "\n\n" )
  end

  def delete_entries( job_ids )
    deleted = 0
    job_ids.each do |job_id|
      # TODO: Inefficient in the free(beer) sidekiq version; 
      #       find something more efficient here (sr 2016-04-06)
      job = dead_set.find_job( job_id )
      if job
        job.delete
        puts "#{job_id}: deleted"
        deleted += 1
      else
        puts "#{job_id}: not found"
      end
    end
    puts "Dead Set: Deleted #{deleted} entries"
  end

  def retry_entries( job_ids )
    retried = 0
    job_ids.each do |job_id|
      # TODO: Inefficient in the free(beer) sidekiq version; 
      #       find something more efficient here (sr 2016-04-06)
      job = dead_set.find_job( job_id )
      if job
        begin
          job.retry
          puts "#{job_id}: retrying"
          retried += 1
        rescue
          puts "#{job_id}: failed - #{$!.message}"
        end
      else
        puts "#{job_id}: not found"
      end
    end

    puts "Dead Set: Retried #{retried} entries"
  end

  def clear
    puts "Dead Set: Deleted #{dead_set.clear} entries"
  end

  protected
  def job_details( job )
    [ "JobID:         #{job.jid}",
      "Created at:    #{job.created_at.strftime( "%F %T" )}",
      "Enqueued at:   #{job.enqueued_at.strftime( "%F %T")}",
      "Worker class:  #{job.display_class}",
      "Arguments:     #{job.display_args}",
      "Failed at:     #{Time.at( job.item["failed_at"] ).strftime( "%F %T" )}",
      "Retried at:    #{job.item["retried_at"] ? Time.at( job.item["retried_at"] ).strftime( "%F %T" ) : "never"}",
      "Retries:       #{job.item["retry_count"]}",
      "Retry?:        #{job.item["retry"]}",
      "Error Class:   #{job.item["error_class"]}",
      "Error Message: #{job.item["error_message"]}"
    ].join( "\n" ) 
  end
end

class Processes
  attr_reader :process_set

  def initialize
    @process_set = Sidekiq::ProcessSet.new
  end

  def to_s
    process_set.each_with_object( ["Processes: #{process_set.size}"] ) do |process, memo|
      memo << process.inspect
    end.join( "\n" )
  end

  def quiet
    size = process_set.size
    process_set.each do |process|
      process.quiet!
    end
    puts "Quieted #{size} processes"
  end

  def kill
    size = process_set.size
    process_set.each do |process|
      process.kill!
    end
    puts "Killed #{size} processes"
  end

  def clean
    cleaned_up = Sidekiq::ProcessSet.cleanup
    puts "Cleaned up #{cleaned_up} processes"
  end
end

class Workers
  attr_reader :worker_set

  def initialize
    @worker_set = Sidekiq::Workers.new
  end

  def to_s
    ary = [ "Workers: #{worker_set.size}" ]

    worker_set.each do |key, tid, json|
      ary << sprintf( "%15s %15s %20s\n", key, tid, json )
    end

    ary.join( "\n" )
  end
end

options = Parser.parse( ARGV )

Sidekiq.configure_client do |config|
  url = options["url"] ||"redis://#{options["host"]}:#{options["port"]}/#{options["db"]}"
  config.redis = { :url  => url, :size => 1 }
end

case ARGV.shift
  when "stats" then puts Stats.new

  when "queue" 
    case ARGV.shift
      when "list" then puts Queues.new
      else Parser.parse( %w[ --help ] )
    end

  when "retry" 
    retries = Retries.new

    case ARGV.shift
      when "list"  then puts retries
      when "show"  then puts retries.details( ARGV )
      when "del"   then retries.delete_entries( ARGV )
      when "kill"  then retries.kill_entries( ARGV )
      when "now"   then retries.retry_entries( ARGV )
      when "clear" then retries.clear
      else Parser.parse( %w[ --help ] )
    end

  when "dead"
    dead = Dead.new

    case ARGV.shift
      when "list"  then puts dead
      when "show"  then puts dead.details( ARGV )
      when "del"   then dead.delete_entries( ARGV )
      when "now"   then dead.retry_entries( ARGV )
      when "clear" then dead.clear
      else Parser.parse( %w[ --help ] )
    end

  when "processes"
    processes = Processes.new

    case ARGV.shift
      when "list"  then puts processes
      when "quiet" then processes.quiet
      when "kill"  then processes.kill
      when "clean" then processes.clean
      else Parser.parse( %w[ --help ] )
    end

  when "workers"
    workers = Workers.new
    case ARGV.shift
      when "list" then puts workers
      else Parser.parse( %w[ --help ] )
    end

  else Parser.parse( %w[ --help ] )
end
