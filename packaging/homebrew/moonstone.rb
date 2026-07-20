class Moonstone < Formula
  desc "Deterministic Lua runtime and package manager"
  homepage "https://moonstone.sh"
  url "https://github.com/moonstone-sh/moonstone/archive/refs/tags/v0.3.24.tar.gz"
  sha256 "SKIP"
  license "MIT"
  head "https://github.com/moonstone-sh/moonstone.git", branch: "main"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe", "-Ddistribution-channel=homebrew", "--prefix", prefix
  end

  test do
    assert_match "Moonstone v", shell_output("#{bin}/moon --version")
  end
end
