# coding: utf-8, frozen_string_literal: true

require 'net/http'
require 'json'
require 'puma'
require 'puma/plugin'

module PumaPluginDogstatsd

  KEY = :puma_plugin_datadog_statsd_client

  def activate(puma_config, datadog_statsd_client)
    raise "'puma_config' should not be nil" if puma_config.nil?
    raise "'datadog_statsd_client' should not be nil" if datadog_statsd_client.nil?

    puma_config.inject { @options[KEY] = datadog_statsd_client }
    puma_config.plugin(:PumaPluginDogstatsd)
  end
  module_function :activate

end

Puma::Plugin.create do

  def start(launcher)
    @launcher = launcher
    @log_writer = @launcher.log_writer

    dogstatsd_client = get_dogstatsd_client(@launcher)
    raise 'PumaPluginDogstatsd: Dogstatsd client not found' if dogstatsd_client.nil?

    clustered = @launcher.send(:clustered?) # See https://github.com/puma/puma/blob/master/lib/puma/launcher.rb#L285

    @log_writer.log "PumaPluginDatadogStatsd - enabled. Cluster mode: #{clustered}"

    in_background do
      sleep 5
      loop do
        begin
          stats = Puma.stats
          @log_writer.debug "PumaPluginDatadogStatsd - notify stats: #{stats}"

          parsed_stats = JSON.parse(stats)

          dogstatsd_client.batch do |s|
            s.gauge('puma.workers', parsed_stats.fetch('workers', 1), tags: tags)
            s.gauge('puma.booted_workers', parsed_stats.fetch('booted_workers', 1), tags: tags)
            s.gauge('puma.running', count_value_for_key(clustered, parsed_stats, 'running'), tags: tags)
            s.gauge('puma.backlog', count_value_for_key(clustered, parsed_stats, 'backlog'), tags: tags)
            s.gauge('puma.pool_capacity', count_value_for_key(clustered, parsed_stats, 'pool_capacity'), tags: tags)
            s.gauge('puma.max_threads', count_value_for_key(clustered, parsed_stats, 'max_threads'), tags: tags)
          end
        rescue StandardError => e
          @log_writer.error "PumaPluginDatadogStatsd - notify stats failed:\n  #{e.to_s}\n  #{e.backtrace.join("\n    ")}"
        ensure
          sleep 2
        end
      end
    end
  end

  private

  def tags
    tags = ["environment:#{Rails.env}"]    

    if ENV.key?('ENVIRONMENT')
      tags << "env:shopvox-#{ENV['ENVIRONMENT']}"
    end

    if ENV.has_key?("STATSD_GROUPING")
      tags << "grouping:#{ENV['STATSD_GROUPING']}"
    end

    # Standardised datadog tag attributes, so that we can share the metric
    # tags with the application running
    #
    # https://docs.datadoghq.com/agent/docker/?tab=standard#global-options
    #
    if ENV.has_key?("DD_TAGS")
      ENV["DD_TAGS"].split(/\s+|,/).each do |t|
        tags << t
      end
    end

    # Support the Unified Service Tagging from Datadog, so that we can share
    # the metric tags with the application running
    #
    # https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging
    if ENV.has_key?("DD_ENV")
      tags << "env:#{ENV["DD_ENV"]}"
    end

    if ENV.has_key?("DD_SERVICE")
      tags << "service:#{ENV["DD_SERVICE"]}"
    end

    if ENV.has_key?("DD_VERSION")
      tags << "version:#{ENV["DD_VERSION"]}"
    end

    # Try to get the reliable Fargate container ID first
    unique_id = get_ecs_container_id

    # As a fallback, try the original hostname method
    unique_id ||= `hostname`.strip

    unless unique_id.to_s.strip.empty?
      # Use a more descriptive tag key like 'container_id'
      tags << "container_id:#{unique_id}"
    end

    tags.join(",")
  end

  def count_value_for_key(clustered, stats, key)
    if clustered
      stats['worker_status'].reduce(0) { |acc, s| acc + s['last_status'].fetch(key, 0) }
    else
      stats.fetch(key, 0)
    end
  end

  def get_dogstatsd_client(launcher)
    launcher.instance_variable_get(:@options)[PumaPluginDogstatsd::KEY]
  end

  def get_ecs_container_id
    # The V4 endpoint is recommended by AWS
    metadata_uri_str = ENV['ECS_CONTAINER_METADATA_URI_V4']
    return nil unless metadata_uri_str

    begin
      uri = URI(metadata_uri_str)
      response = Net::HTTP.get(uri)
      metadata = JSON.parse(response)

      # The 'ContainerARN' provides a globally unique identifier.
      # We can extract the short container ID from the end of the ARN for a cleaner tag.
      # e.g., arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc.../def...
      # The last part is the container's unique ID.
      container_arn = metadata['ContainerARN']
      return container_arn.split('/').last if container_arn&.include?('/')
    rescue => e
      @log_writer.error "PumaPluginDatadogStatsd - Unable to retrieve container metadata:\n  #{e.to_s}\n  #{e.backtrace.join("\n")}"
      return nil
    end
  end
end
