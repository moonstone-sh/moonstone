local argparse = require("argparse")

















local CLI = {}




function CLI.parse(args)
   local new_parser = argparse
   local p = new_parser("teal-cli", "A modern Teal CLI application built with Moonstone and Ballad.")

   p:option("-n --name", "Name of the person or subject to greet", "World")
   p:option("-g --greeting", "Custom greeting phrase to use", "Hello")
   p:option("-c --count", "Number of times to repeat the greeting", "1"):
   convert(tonumber)
   p:flag("-v --verbose", "Enable verbose debug output")

   local opts = p:parse(args)
   return opts
end

function CLI.run(opts)
   if opts.verbose then
      print("[DEBUG] Running teal-cli with count=" .. tostring(opts.count))
   end

   local count = opts.count or 1
   for i = 1, count do
      print(string.format("[%d/%d] %s, %s!", i, count, opts.greeting or "Hello", opts.name or "World"))
   end
end

return CLI
