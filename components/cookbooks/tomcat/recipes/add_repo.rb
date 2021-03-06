
major_version = node.workorder.rfcCi.ciAttributes.version.gsub(/\..*/,"")
tomcat_version_name = "tomcat"+major_version

# tomcat reinstalls correct version for a few cases
case node.platform
when /fedora|redhat|centos/
  package "perl" do
    action :remove
  end
end

tomcat_pkgs = value_for_platform(
  ["debian","ubuntu"] => {
    "default" => [tomcat_version_name, tomcat_version_name+"-admin"]
  },
  ["centos","redhat","fedora"] => {
                                 # wmt internal rhel 6.2 repo doesnt have tomcatX-admin-webapps
                                 #"default" => [tomcat_version_name,tomcat_version_name+"-admin-webapps"]
                                 "default" => [tomcat_version_name]
  },
  "default" => [tomcat_version_name]
)

# Fix package install failure due to metadata expiry
if platform_family?("rhel")
  execute 'yum clean metadata' do
    user 'root'
    group 'root'
  end
end

tomcat_pkgs.each do |pkg|
  # debian workaround for parallel dpkg/apt-get calls
  if node.platform !~ /fedora|redhat|centos/
    ruby_block 'Check for dpkg lock' do
      block do
        sleep rand(10)
        retry_count = 0
        while system('lsof /var/lib/dpkg/lock') && retry_count < 20
          Chef::Log.warn("Found lock. Will retry package #{name} in #{node.workorder.rfcCi.ciName}")
          sleep rand(5)+10
          retry_count += 1
        end
      end
    end
  end
  package pkg do
    Chef::Log.warn("We are installing #{pkg}")
    action :install
  end
end

package "#{tomcat_version_name}-admin-webapps" do
  only_if { ["redhat","centos"].include?(node.platform) }
end

template "/etc/#{tomcat_version_name}/server.xml" do
  source "server#{major_version}.xml.erb"
  owner "root"
  group "root"
  mode "0644"
end



template "/etc/#{tomcat_version_name}/tomcat-users.xml" do
  source "tomcat-users.xml.erb"
  owner "root"
  group "root"
  mode "0644"
end

template "/etc/#{tomcat_version_name}/Catalina/localhost/manager.xml" do
  source "manager.xml.erb"
  owner "root"
  group "root"
  mode "0644"
end


directory "/etc/#{tomcat_version_name}/policy.d" do
  action :create
  owner "root"
  group "root"
end

template "/etc/#{tomcat_version_name}/policy.d/50local.policy" do
  source "50local.policy.erb"
  owner "root"
  group "root"
  mode "0644"
end


tomcat_env_setup = "/etc/default/#{tomcat_version_name}"
case node["platform"]
when "centos","redhat","fedora"
  tomcat_env_setup = "/etc/sysconfig/#{tomcat_version_name}"
end


if node["tomcat"].has_key?("environment")
  envMap = JSON.parse(node["tomcat"]["environment"])
  node.set['tomcat']['override_default_init']='false'
  node.set['tomcat']['override_default_init'] = envMap.has_key?('OVERRIDE_DEFAULT_INIT') && envMap['OVERRIDE_DEFAULT_INIT']=='true'
  Chef::Log.info("Should override_default_init : #{node.tomcat.override_default_init}")
end


template "/etc/init.d/tomcat6" do
  only_if { node.tomcat.override_default_init=='true'}
  source "tomcat#{major_version}_initd.erb"
  owner "root"
  group "root"
  mode "0755"
end

template tomcat_env_setup do
  source "default_#{tomcat_version_name}.erb"
  owner "root"
  group "root"
  mode "0644"
end



unless node["tomcat"]["access_log_dir"].start_with?("/")
  node.set['tomcat']['access_log_dir'] = "/var/log/tomcat#{major_version}/"
end
Chef::Log.info("Installation type #{node[:tomcat][:install_type]} - aceess log #{node[:tomcat][:access_log_dir]}")
