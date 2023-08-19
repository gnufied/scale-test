require 'fileutils'
require 'thread'

require 'json'

class UpgradeOCP
  include FileUtils

  INSTALL_COMMAND = "./openshift-install create cluster"
  MACHINE_COUNT = 11
  RUNNING_STATE = "Running"

  POD_NAMESPACE = "emacs"
  POD_COUNT = 300

  VERSION_413 = "4.13.9"
  VERSION_414 = "4.14.0-0.nightly-2023-08-11-055332"

  KUBELET_REGEXP_413 = Regexp.new("v1\.26\.6")
  KUBELET_REGEXP_414 = Regexp.new("v1\.27\.4")

  IMAGE_413 = "quay.io/openshift-release-dev/ocp-release:4.13.9-x86_64"
  IMAGE_414 = "registry.ci.openshift.org/ocp/release:4.14.0-0.nightly-2023-08-11-055332"

  def build_upgrade_destroy_loop
    loop do
      log("Installing new cluster")
      self.install_cluster()
      log("Waiting for 30 minutes before starting next cluster")
      sleep(30 * 60)
    end
  end

  def install_cluster
    self.start_install()
    self.set_kubeconfig()

    self.scale_machinesets(MACHINE_COUNT)
    self.wait_for_machines(MACHINE_COUNT)
    self.create_pods(POD_NAMESPACE, POD_COUNT)

    self.upgrade_cluster(IMAGE_413)
    self.wait_for_upgrade(VERSION_413)
    self.wait_for_nodes_upgrade(KUBELET_REGEXP_413)

    # Wait for all nodes to be ready
    self.wait_for_nodes_ready

    # make sure that pods are still running after upgrade
    log("********** Checking if pods are still running after 4.13 upgrade **********")
    self.wait_for_running_pods(POD_NAMESPACE, POD_COUNT)

    log("********** Upgrading to 4.14 **********")
    self.upgrade_cluster(IMAGE_414)
    self.wait_for_upgrade(VERSION_414)
    self.wait_for_nodes_upgrade(KUBELET_REGEXP_414)

    self.wait_for_nodes_ready

    log("Upgrade to 4.14 is finished")

    # make sure that pods are still running after upgrade
    log("********** Checking if pods are still running after 4.14 upgrade **********")
    self.wait_for_running_pods(POD_NAMESPACE, POD_COUNT)

    self.delete_pods(POD_NAMESPACE, POD_COUNT)
    self.wait_for_pod_removal()
    self.wait_for_pv_removal()

    log("destroy the cluster")

    self.destroy_cluster()
  end

  def wait_for_install_finish
    loop do
      log("Checking if installer is still running")
      if @install_thread.alive?
        log("Looks like installer is still running")
      else
        log("Installation finished")
        break
      end
      sleep(20)
    end
  end

  def wait_for_nodes_ready
    loop do
      system("oc wait --for=condition=Ready nodes --all --timeout=600s || return 1")
      if $?.exitstatus == 0
        break
      end
    end
  end

  def get_item_list(item_name)
    item_raw = `oc get #{item_name} -o json`
    JSON.parse(item_raw)['items']
  end

  def set_kubeconfig()
    ENV['KUBECONFIG'] = "/home/hekumar/ocp-vs412/auth/kubeconfig"
  end

  def upgrade_cluster(image_name)
    system("oc adm upgrade --to-image=#{image_name} --force --allow-explicit-upgrade")
  end

  def wait_for_upgrade(version_to_check)
    loop do
      cluster_version_raw = `oc get clusterversion -o json`
      cluster_version_json = JSON.load(cluster_version_raw)
      cluster_version_histories = cluster_version_json['items'][0]['status']['history'] rescue []
      upgrade_finished = false

      cluster_version_histories.each do |history|
        exact_cluster_version = history['version']
        cluster_version_state = history['state']
        log("Current version is #{exact_cluster_version} and state is #{cluster_version_state}")
        if exact_cluster_version == version_to_check && cluster_version_state == "Completed"
          upgrade_finished = true
          log("Cluster upgrade completed")
        end
      end

      if upgrade_finished
        break
      else
        sleep(20)
      end
    end
  end

  def wait_for_nodes_upgrade(kubelet_regexp)
    loop do
      nodes_upgraded = true
      nodes_raw = `oc get nodes -o json`
      node_list = JSON.load(nodes_raw)['items']
      node_list.each do |node_dict|
        kubelet_version = node_dict['status']['nodeInfo']['kubeletVersion']
        node_name = get_resource_name(node_dict)
        if !kubelet_regexp.match?(kubelet_version)
          log("Found node #{node_name} with kubelet version #{kubelet_version}, still waiting")
          nodes_upgraded = false
        end
      end

      if nodes_upgraded
        break
      else
        sleep(20)
      end
    end
  end

  def enable_migration
    system("./patch_migration.sh")
  end

  def wait_for_migration
    loop do
      system("oc wait --for=condition=VSphereMigrationControllerAvailable=True --timeout=20s storage cluster || return 1")
      if $?.exitstatus == 0
        log("CSI migration enabled")
        break
      end
    end
  end


  def log(msg)
    puts "#{Time.now} #{msg}"
  end

  def start_install
    cd("#{ENV['HOME']}/ocp-vs412") do
      cp("#{ENV['HOME']}/persona-secrets/install-config-412-ibm-devqe-persistent.yaml", "install-config.yaml")
      system(INSTALL_COMMAND)
    end
  end

  def destroy_cluster
    cd("#{ENV['HOME']}/ocp-vs412") do
      system("./openshift-install destroy cluster")
    end
  end

  def scale_machinesets(replica_count)
    raw_machineset = `oc get -n openshift-machine-api machinesets.machine.openshift.io -o json`
    machineset_json = JSON.load(raw_machineset)
    machine_set = get_resource_name(machineset_json["items"][0])
    log "Scaling machineset #{machine_set}"
    system("oc scale --replicas=#{replica_count} machineset.machine.openshift.io #{machine_set} -n openshift-machine-api")
  end

  def wait_for_machines(replica_count)
    loop do
      raw_machines = `oc get -n openshift-machine-api machines.machine.openshift.io -o json`
      machine_json = JSON.load(raw_machines)["items"]
      machines_ready = true

      if machine_json.length < replica_count
        log "Found only #{machine_json.length} machines, waiting for #{replica_count}"
        machines_ready = false
      end

      if machines_ready
        machine_json.each do |machine|
          machine_status = machine["status"]["phase"] rescue ""
          if machine_status != RUNNING_STATE
            log("found machine #{get_resource_name(machine)} in #{machine_status}, waiting for #{RUNNING_STATE}")
            machines_ready = false
          end
        end
      end

      if machines_ready
        break
      else
        sleep(10)
      end
    end
  end

  def create_pods(namespace, count)
    (0..count).each do |i|
      namespace_base=namespace
      log "Namespace base is #{namespace_base}"
      if namespace_base == nil || namespace_base.empty?
        namespace_base = "emacs"
      end

      system("oc create namespace #{namespace_base}#{i}")
      system("oc create -f deployment.yaml -n #{namespace_base}#{i}")
    end

    self.wait_for_running_pods(namespace, count)
  end

  def delete_pods(namespace, count)
    (0..count).each do |i|
      namespace_base=namespace
      puts "Namespace base is #{namespace_base}"
      if namespace_base == nil || namespace_base.empty?
        namespace_base = "emacs"
      end
      system("oc delete namespace --wait=false #{namespace_base}#{i}")
    end
  end

  def wait_for_pod_removal
    loop do
      pods_json_raw = `oc get pods -l run=sandbox --all-namespaces -o json`
      pod_json = JSON.load(pods_json_raw)
      pod_items = pod_json["items"]
      if pod_items.length > 0
        log("found #{pod_items.length} pods")
        sleep(20)
      else
        puts "No pods found"
        break
      end
    end
  end

  def wait_for_pv_removal
    loop do
      pvs_list_raw = `oc get pv -o json`
      pvs = JSON.load(pvs_list_raw)
      pv_items = pvs["items"]
      if pv_items.length > 0
        log("found #{pv_items.length} pvs")
        sleep(20)
      else
        puts "No pvs found"
        break
      end
    end
  end

  def wait_for_running_pods(namespace, count)
    log("Waiting for all pods to be running")
    (0..count).each do |i|
      namespace_base = namespace
      system("oc wait --for=condition=ready -n #{namespace_base}#{i} pod -l run=sandbox --timeout=4m || return 1")
      if $?.exitstatus != 0
        log("One or more pods failed to start, please investigate the cause")
        exit(1)
      end
    end
  end

  def get_resource_name(resource)
    resource["metadata"]["name"]
  end
end

class Object
  def blank?
    respond_to?(:empty?) ? empty? : !self
  end

  # An object is present if it's not blank.
  def present?
    !blank?
  end

  def presence
    self if present?
  end
end

class NilClass #:nodoc:
  def blank?
    true
  end
end

class FalseClass # :nodoc:
  def blank?
    true
  end
end

class TrueClass # :nodoc:
  def blank?
    false
  end
end

class Array #:nodoc:
  alias_method :blank?, :empty?
end

class Hash #:nodoc:
  alias_method :blank?, :empty?
end

class String #:nodoc:
  def blank?
    self !~ /\S/
  end
end

class Numeric #:nodoc:
  def blank?
    false
  end
end

UpgradeOCP.new().build_upgrade_destroy_loop
