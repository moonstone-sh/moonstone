local argparse = require("argparse")

local record Parser
  option: function(Parser, string, string, string): Parser
  flag: function(Parser, string, string): Parser
  convert: function(Parser, function(string): any): Parser
  parse: function(Parser, {string}): any
end

local type CliParserFn = function(string, string): Parser

local record CliOptions
  name: string
  greeting: string
  count: integer
  verbose: boolean
end

local record CLI
  parse: function(args: {string}): CliOptions
  run: function(opts: CliOptions)
end

function CLI.parse(args: {string}): CliOptions
  local new_parser = argparse as CliParserFn
  local p = new_parser("teal-cli", "A modern Teal CLI application built with Moonstone and Ballad.")
  
  p:option("-n --name", "Name of the person or subject to greet", "World")
  p:option("-g --greeting", "Custom greeting phrase to use", "Hello")
  p:option("-c --count", "Number of times to repeat the greeting", "1")
   :convert(tonumber)
  p:flag("-v --verbose", "Enable verbose debug output")

  local opts = p:parse(args) as CliOptions
  return opts
end

function CLI.run(opts: CliOptions)
  if opts.verbose then
    print("[DEBUG] Running teal-cli with count=" .. tostring(opts.count))
  end

  local count = opts.count or 1
  for i = 1, count do
    print(string.format("[%d/%d] %s, %s!", i, count, opts.greeting or "Hello", opts.name or "World"))
  end
end

return CLI
