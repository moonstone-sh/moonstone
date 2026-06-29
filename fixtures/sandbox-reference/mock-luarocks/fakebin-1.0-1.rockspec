
package = "fakebin"
version = "1.0-1"
source = {
   url = "http://localhost:8641/fakebin-1.0.tar.gz"
}
description = {
   summary = "A fake bin rock for testing"
}
dependencies = {
   "lua >= 5.1"
}
build = {
   type = "builtin",
   modules = {},
   install = {
      bin = {
         fakebin = "fake.lua"
      }
   }
}
