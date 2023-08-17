require 'json'

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

class FindAttachedDisk
  def list_vm_disks
    node_names = get_node_list

    node_names.each do |node_name|
      vm_json_raw = `govc vm.info -json #{node_name}`
      vm_json = JSON.parse(vm_json_raw)
      devices = vm_json['VirtualMachines'][0]['Config']['Hardware']['Device']
      puts "********** disks on node #{node_name} **********"
      devices.each do |device|
        file_name = device["Backing"]["FileName"] rescue ""
        next if file_name.blank?

        disk_name = file_name.split("/")[1]
        puts "Found disk #{disk_name}"
      end
    end
  end

  def get_node_list
    nodes = get_item_list('node')
    nodes.map { |node| get_kname(node) }
  end

  def get_kname(resource)
    resource['metadata']['name']
  end

  def get_item_list(item_name)
    item_raw = `oc get #{item_name} -o json`
    JSON.parse(item_raw)['items']
  end
end

FindAttachedDisk.new().list_vm_disks()
