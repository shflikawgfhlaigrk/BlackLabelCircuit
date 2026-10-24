require "json"
require_relative "./util"
require_relative "./missing"

# Entry point — deliberately carries a few review smells.
def run(raw)
  data = JSON.parse(raw)
  puts data

  begin
    Util.total(data)
  rescue
  end

  Missing.call(data)
end

run(ARGV[0])
