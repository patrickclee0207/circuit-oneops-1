require 'fog'

class VirtualMachineManager
  USER = 'root'
  PASSWORD = ''
  def initialize(compute_provider, public_key, instance_id = nil)
    fail ArgumentError, 'compute_provider is invalid' if compute_provider.nil?
    fail ArgumentError, 'public_key is invalid' if public_key.nil?

    @compute_provider = compute_provider
    @instance_id = instance_id
    @public_key = public_key
  end

  attr_reader :instance_id

  def ip_address
    ip_address = get_ip_address
  end

  def inject_public_Key
    fail ArgumentError, 'instance_id is invalid' if @instance_id.nil? || @instance_id.empty?

    options = {}
    options['instance_uuid'] = @instance_id
    options['user'] = USER
    options['password'] = PASSWORD
    options['command'] = '/usr/bin/echo'
    options['args'] = @public_key.chomp + ' > authorized_keys'
    options['working_dir'] = '/root/.ssh'

    time_to_live = 180
    start_time = Time.now
    is_public_key_injected = false
    Chef::Log.info("waiting to inject public key")
    loop do
      begin
        @compute_provider.vm_execute(options)
        is_public_key_injected = true
        break
      rescue
        Chef::Log.info("waiting to inject public key 10sec; TTL is " + time_to_live.to_s + " seconds")
        sleep(10)
        break if Time.now > start_time + time_to_live
      end
    end
    return is_public_key_injected
  end
  private :inject_public_Key

  def throttle_yum(data_rate_KBps)
    fail ArgumentError, 'instance_id is invalid' if @instance_id.nil? || @instance_id.empty?

    options = {}
    options['instance_uuid'] = @instance_id
    options['user'] = USER
    options['password'] = PASSWORD
    options['command'] = '/usr/bin/echo'
    options['args'] = "throttle=#{data_rate_KBps}k" + ' >> yum.conf'
    options['working_dir'] = '/etc'

    time_to_live = 180
    start_time = Time.now
    is_yum_throttled = false
    Chef::Log.info("waiting for yum throttle config")
    loop do
      begin
        @compute_provider.vm_execute(options)
        is_yum_throttled = true
        break
      rescue
        Chef::Log.info("waiting for yum throttle config 10sec; TTL is " + time_to_live.to_s + " seconds")
        sleep(10)
        break if Time.now > start_time + time_to_live
      end
    end
    return is_yum_throttled
  end
  private :throttle_yum

  def get_ip_address
    fail ArgumentError, 'instance_id is invalid' if @instance_id.nil? || @instance_id.empty?

    time_to_live = 180
    start_time = Time.now
    ip_address = nil
    Chef::Log.info("waiting for ip address")
    loop do
      response = @compute_provider.get_virtual_machine(@instance_id)
      ip_address = response['ipaddress']
      if !ip_address.nil?
        break
      else
        Chef::Log.info("waiting for ip address 10sec; TTL is " + time_to_live.to_s + " seconds")
        sleep(10)
        break if Time.now > start_time + time_to_live
      end
    end

    return ip_address
  end
  private :get_ip_address

  def power_on(initial_boot, data_transfer_rate = nil)
    fail ArgumentError, 'instance_id is invalid' if @instance_id.nil? || @instance_id.empty?

    is_power_on = false
    Chef::Log.info("powering on instance")
    @compute_provider.vm_power_on({'instance_uuid' => @instance_id})

    if initial_boot == true
      inject_public_Key
      throttle_yum(data_transfer_rate) if !data_transfer_rate.nil?
    end
    ip_address = get_ip_address
    is_power_on = true if !ip_address.nil?
    return is_power_on
  end
  private :power_on

  def clone(vm_attributes, service_compute, is_debug)
    is_bandwidth_throttled = service_compute[:is_bandwidth_throttled]
    data_transfer_rate = service_compute[:data_transfer_rate]

    begin
      new_vm = @compute_provider.vm_clone(vm_attributes)
      @instance_id = new_vm['new_vm']['id']
      if is_bandwidth_throttled == 'true'
        power_on(initial_boot = true, data_transfer_rate)
      else
        power_on(initial_boot = false)
      end
    rescue => e
      Chef::Log.error('Cloning instance failed:' + e.to_s)
      if (!@instance_id.nil?) && (is_debug == 'false')
        Chef::Log.error('Deleting failed instance')
        delete
      end
      exit 1
    end

    return @instance_id
  end

  def power_off(force)
    fail ArgumentError, 'instance_id is invalid' if @instance_id.nil? || @instance_id.empty?

    options = {}
    options['instance_uuid'] = @instance_id
    options['force'] = force
    @compute_provider.vm_power_off(options)

    time_to_live = 180
    start_time = Time.now
    is_power_off = false
    Chef::Log.info("powering off instance")
    loop do
      response = @compute_provider.get_virtual_machine(@instance_id)
      power_state = response['power_state']
      if power_state == 'poweredOff'
        is_power_off = true
        break
      else
        Chef::Log.info("waiting for instance to power off 10sec; TTL is " + time_to_live.to_s + " seconds")
        sleep(10)
        break if Time.now > start_time + time_to_live
      end
    end
    return is_power_off
  end
  private :power_off

  def reboot
    is_rebooted = false
    begin
      is_power_off = power_off(force = false)
      if is_power_off == true
        is_power_on = power_on(initial_boot = false)
        is_rebooted = true if is_power_on == true
      end
    rescue => e
      Chef::Log.error('Rebooting instance failed:' + e.to_s)
      exit 1
    end
    return is_rebooted
  end

  def powercycle
    is_powercycled = false
    begin
      is_power_off = power_off(force = true)
      if is_power_off == true
        is_power_on = power_on(initial_boot = false)
        is_powercycled = true if is_power_on == true
      end
    rescue => e
      Chef::Log.error('Powercycling instance failed:' + e.to_s)
      exit 1
    end
    return is_powercycled
  end

  def get_virtual_machine
    fail ArgumentError, 'instance_id is invalid' if @instance_id.nil? || @instance_id.empty?

    virtual_machine = nil
    begin
      virtual_machine = @compute_provider.get_virtual_machine(@instance_id)
    rescue
      virtual_machine = nil
    end
    return virtual_machine
  end
  private :get_virtual_machine

  def delete
    fail ArgumentError, 'instance_id is invalid' if @instance_id.nil? || @instance_id.empty?

    is_deleted = false
    begin
      virtual_machine = get_virtual_machine
      if !virtual_machine.nil?
        if power_off(force = true)
          response = @compute_provider.vm_destroy({'instance_uuid' => @instance_id})
          is_deleted = true if response['task_state'] == 'success'
        end
      else
        Chef::Log.warn("VM Not Found")
      end
    rescue => e
      response = @compute_provider.vm_destroy({'instance_uuid' => @instance_id})
      is_deleted = true if response['task_state'] == 'success'
      Chef::Log.error('Deleting instance failed: ' + e.to_s) if is_deleted = false
      exit 1
    end
    return is_deleted
  end
end
