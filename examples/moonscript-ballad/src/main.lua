local User
User = require("user").User
local user = User("Ada Lovelace", "ada@example.com", "admin")
print("=== User Info ===")
print("Name:  " .. tostring(user.name))
print("Email: " .. tostring(user.email))
print("Role:  " .. tostring(user.role))
print("\n=== Encoded JSON ===")
local json_output = user:to_json()
print(json_output)
print("\n=== Decoded Back ===")
local restored_user = User.from_json(json_output)
return print("Restored: " .. tostring(restored_user.name) .. " (" .. tostring(restored_user.email) .. ")")
