package.path = "src/?.lua;src/?.moon;" .. package.path

{ :User } = require "user"

describe "User class", ->
  it "initializes with default role", ->
    u = User "Alice", "alice@example.com"
    assert.equal "Alice", u.name
    assert.equal "alice@example.com", u.email
    assert.equal "developer", u.role

  it "serializes to JSON correctly", ->
    u = User "Bob", "bob@example.com", "lead"
    json = u\to_json!
    assert.truthy json\find "Bob"
    assert.truthy json\find "bob@example.com"

  it "deserializes from JSON correctly", ->
    u = User "Carol", "carol@example.com", "designer"
    json = u\to_json!
    restored = User.from_json json
    assert.equal "Carol", restored.name
    assert.equal "carol@example.com", restored.email
    assert.equal "designer", restored.role
