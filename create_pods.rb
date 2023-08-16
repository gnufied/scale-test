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

  system("oc create namespace #{namespace_base}#{i}")
  system("oc create -f deployment.yaml -n #{namespace_base}#{i}")
end
