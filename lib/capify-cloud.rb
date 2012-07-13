require 'rubygems'
require 'fog'
require 'colored'
require File.expand_path(File.dirname(__FILE__) + '/capify-cloud/server')


class CapifyCloud

  attr_accessor :instances
  
  def initialize(cloud_config = "config/cloud.yml")
    case cloud_config
    when Hash
      @cloud_config = cloud_config
    when String
      @cloud_config = YAML.load_file cloud_config
    else
      raise ArgumentError, "Invalid cloud_config: #{cloud_config.inspect}"
    end

    @cloud_providers = @cloud_config[:cloud_providers]
    @instances = []
    @cloud_providers.each do |cloud_provider|
      config = @cloud_config[cloud_provider.to_sym]
      config[:provider] = cloud_provider
        regions = determine_regions(cloud_provider)
        config.delete(:regions)
        if regions
          regions.each do |region|
            config.delete(:region)
            config[:region] = region

            servers = Fog::Compute.new(config).servers
            servers.each do |server|
              @instances << server if server.ready?
            end
          end
        else
          servers = Fog::Compute.new(config).servers
          servers.each do |server|
            @instances << server if server.ready?
        end
      end
    end
  end 
  
  def determine_regions(cloud_provider = 'AWS')
    regions = @cloud_config[cloud_provider.to_sym][:regions]
  end
    
  def display_instances
    desired_instances.each_with_index do |instance, i|
      puts sprintf "%02d:  %-40s  %-20s %-20s  %-20s  %-25s  %-20s  (%s)  (%s)",
        i, (instance.name || "").green, instance.provider.yellow, instance.id.red, instance.flavor_id.cyan,
        instance.contact_point.blue, instance.zone_id.magenta, (instance.tags["Roles"] || "").yellow,
        (instance.tags["Options"] || "").yellow
      end
  end

  def server_names
    desired_instances.map {|instance| instance.name}
  end
    
  def project_instances
    @instances.select {|instance| instance.tags["Project"] == @cloud_config[:project_tag]}
  end
  
  def desired_instances
    @cloud_config[:project_tag].nil? ? @instances : project_instances
  end
 
  def get_instances_by_role(role)
    desired_instances.select {|instance| instance.tags['Roles'].split(%r{,\s*}).include?(role.to_s) rescue false}
  end
  
  def get_instances_by_region(roles, region)
    return unless region
    desired_instances.select {|instance| instance.availability_zone.match(region) && instance.roles == roles.to_s rescue false}
  end 
  
  def get_instance_by_name(name)
    desired_instances.select {|instance| instance.name == name}.first
  end
end
