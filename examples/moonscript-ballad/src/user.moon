dkjson = require "dkjson"

class User
  new: (@name, @email, @role = "developer") =>

  to_table: =>
    {
      name: @name
      email: @email
      role: @role
    }

  to_json: =>
    dkjson.encode @to_table!, { indent: true }

  @from_json: (json_str) ->
    data = dkjson.decode json_str
    User data.name, data.email, data.role

{ :User }

-- cache invalidation test user.moon
