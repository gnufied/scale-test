require 'json'

count_arg = ARGV[1]
count = 28
if count_arg != nil && !count_arg.empty?
  count = count_arg.to_i
end

(0..count).each do |i|
  namespace_base=ARGV[0]
  puts "Namespace base is #{namespace_base}"
  if namespace_base == nil || namespace_base.empty?
    namespace_base = "emacs"
  end
  system("oc delete namespace --wait=false #{namespace_base}#{i}")
end

def wait_for_pod_removal
  loop do
    pods_json_raw = `oc get pods -l run=sandbox --all-namespaces -o json`
    pod_json = JSON.load(pods_json_raw)
    pod_items = pod_json["items"]
    if pod_items.length > 0
      puts("found #{pod_items.length} pods")
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
      puts("found #{pv_items.length} pvs")
      sleep(20)
    else
      puts "No pvs found"
      break
    end
  end
end

wait_for_pod_removal()

wait_for_pv_removal()
