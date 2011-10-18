require 'rubygems'
require 'fog'
require 'colored'
require File.expand_path(File.dirname(__FILE__) + '/capify-ec2/server')
#require File.expand_path(File.dirname(__FILE__) + '/capify-ec2/instances')

class CapifyEc2

  attr_accessor :load_balancer
  SLEEP_COUNT = 5
  
  def initialize()
    @ec2_config = YAML.load(File.new("config/ec2.yml"))
    regions = determine_regions()
    
    @instances = []
    regions.each do |region|
      servers = Fog::Compute.new(:provider => 'AWS', :aws_access_key_id => @ec2_config[:aws_access_key_id], 
        :aws_secret_access_key => @ec2_config[:aws_secret_access_key], :region => region).servers
      servers.each {|server| @instances << server if server.ready?}
    end
  end 
  
  def determine_regions(region = nil)
    region.nil? ? (@ec2_config[:aws_params][:regions] || [@ec2_config[:aws_params][:region]]) : [region]
  end
  
  def project_instances(project_tag)
    @instances.select {|instance| instance.tags["Project"] == project_tag}
  end
  
  def display_instances
    @instances.each_with_index do |instance, i|
      puts sprintf "%-11s:   %-40s %-20s %-20s %-62s %-20s (%s)",
        i.to_s.magenta, instance.case_insensitive_tag("Name"), instance.id.red, instance.flavor_id.cyan,
        instance.dns_name.blue, instance.availability_zone.green, instance.roles.join(", ").yellow
      end
  end
  
  def regional_instances(region)
    @instances.select {|instance| instance.availability_zone.match(region)}
  end
  
  def running_instances(region = nil)
    instances = @ec2_config[:project_tag].nil? ? @instances : project_instances(@ec2_config[:project_tag])
    instances.each {|instance| p instance.tags}
  end
  
  def instance_health(load_balancer, instance)
    elb.describe_instance_health(load_balancer.id, instance.id).body['DescribeInstanceHealthResult']['InstanceStates'][0]['State']
  end
  
  def get_instances_by_role(role)
    filter_instances_by_role(running_instances, role)
  end
  
  def get_instances_by_region(role, region)
    return unless region
    region_instances = running_instances(region)
    filter_instances_by_role(region_instances,role)
  end 
  
  def filter_instances_by_role(instances, role)
    selected_instances = instances.select do |instance|
      server_roles = [instance.case_insensitive_tag("Role")] || []
      if (roles_tag = instance.case_insensitive_tag("Roles"))        
        server_roles += roles_tag.split(/\s*,\s*/)
      end
      server_roles.member?(role.to_s)
    end
  end 
  
  def get_instance_by_name(name)
    selected_instances = running_instances.select do |instance|
      value = instance.case_insensitive_tag("Name")
      value == name.to_s
    end.first
  end
  
  def server_names
    running_instances.map {|instance| instance.case_insensitive_tag("Name")}
  end
  
  def elb
    Fog::AWS::ELB.new(:aws_access_key_id => @ec2_config[:aws_access_key_id], :aws_secret_access_key => @ec2_config[:aws_secret_access_key], :region => @ec2_config[:aws_params][:region])
  end 
  
  def get_load_balancer_by_instance(instance_id)
    hash = elb.load_balancers.inject({}) do |collect, load_balancer|
      load_balancer.instances.each {|load_balancer_instance_id| collect[load_balancer_instance_id] = load_balancer}
      collect
    end
    hash[instance_id]
  end
  
  def get_load_balancer_by_name(load_balancer_name)
    lbs = {}
    elb.load_balancers.each do |load_balancer|
      lbs[load_balancer.id] = load_balancer
    end
    lbs[load_balancer_name]

  end
     
  def deregister_instance_from_elb(instance_name)
    return unless @ec2_config[:load_balanced]
    instance = get_instance_by_name(instance_name)
    return if instance.nil?
    @@load_balancer = get_load_balancer_by_instance(instance.id)
    return if @@load_balancer.nil?

    elb.deregister_instances_from_load_balancer(instance.id, @@load_balancer.id)
  end
  
  def register_instance_in_elb(instance_name, load_balancer_name = '')
    return if !@ec2_config[:load_balanced]
    instance = get_instance_by_name(instance_name)
    return if instance.nil?
    load_balancer =  get_load_balancer_by_name(load_balancer_name) || @@load_balancer
    return if load_balancer.nil?

    elb.register_instances_with_load_balancer(instance.id, load_balancer.id)

    fail_after = @ec2_config[:fail_after] || 30
    state = instance_health(load_balancer, instance)
    time_elapsed = 0
    
    while time_elapsed < fail_after
      break if state == "InService"
      sleep SLEEP_COUNT
      time_elapsed += SLEEP_COUNT
      STDERR.puts 'Verifying Instance Health'
      state = instance_health(load_balancer, instance)
    end
    if state == 'InService'
      STDERR.puts "#{instance.name}: Healthy"
    else
      STDERR.puts "#{instance.name}: tests timed out after #{time_elapsed} seconds."
    end
  end
end