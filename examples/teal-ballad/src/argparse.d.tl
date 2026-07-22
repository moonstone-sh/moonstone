local record Parser
  option: function(Parser, string, string, string): Parser
  flag: function(Parser, string, string): Parser
  convert: function(Parser, function(string): any): Parser
  parse: function(Parser, {string}): any
end

local record argparse
  {function(string, string): Parser}
end

return argparse
