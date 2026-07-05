class Moonstone < Formula
  desc "Next-generation package manager for Lua"
  homepage "https://moonstone.sh"
  version "0.4.0"
  
  # Homebrew formula using our pre-compiled release binaries
  if OS.mac?
    if Hardware::CPU.arm?
      url "https://github.com/moonstone-sh/moonstone/releases/download/v#{version}/moon-macos-aarch64.tar.gz"
      # sha256 "..." # Added by release CI
    else
      url "https://github.com/moonstone-sh/moonstone/releases/download/v#{version}/moon-macos-x86_64.tar.gz"
      # sha256 "..."
    end
  elsif OS.linux?
    if Hardware::CPU.arm?
      url "https://github.com/moonstone-sh/moonstone/releases/download/v#{version}/moon-linux-aarch64.tar.gz"
      # sha256 "..."
    else
      url "https://github.com/moonstone-sh/moonstone/releases/download/v#{version}/moon-linux-x86_64.tar.gz"
      # sha256 "..."
    end
  end

  def install
    bin.install "moon"
    
    # Generate and automatically link shell completions system-wide
    # Homebrew natively intercepts these and puts them in /opt/homebrew/share/zsh/site-functions
    generate_completions_from_executable(bin/"moon", "completions", "--shell")
  end

  test do
    system "#{bin}/moon", "--version"
  end
end
