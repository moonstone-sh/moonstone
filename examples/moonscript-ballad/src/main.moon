package.path = "src/?.lua;src/?.moon;" .. package.path

{ :User } = require "user"

user = User "Ada Lovelace", "ada@example.com", "admin"

print "=== User Info ==="
print "Name:  #{user.name}"
print "Email: #{user.email}"
print "Role:  #{user.role}"

print "\n=== Encoded JSON ==="
json_output = user\to_json!
print json_output

print "\n=== Decoded Back ==="
restored_user = User.from_json json_output
print "Restored: #{restored_user.name} (#{restored_user.email})"

-- cache invalidation test
