local dkjson = require("dkjson")
local User
do
  local _class_0
  local _base_0 = {
    to_table = function(self)
      return {
        name = self.name,
        email = self.email,
        role = self.role
      }
    end,
    to_json = function(self)
      return dkjson.encode(self:to_table(), {
        indent = true
      })
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self, name, email, role)
      if role == nil then
        role = "developer"
      end
      self.name, self.email, self.role = name, email, role
    end,
    __base = _base_0,
    __name = "User"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  local self = _class_0
  self.from_json = function(json_str)
    local data = dkjson.decode(json_str)
    return User(data.name, data.email, data.role)
  end
  User = _class_0
end
return {
  User = User
}
