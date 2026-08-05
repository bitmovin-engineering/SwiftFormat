class SwiftformatBitmovin < Formula
  desc "Formatting and custom linting tool for Swift code"
  homepage "https://github.com/bitmovin-engineering/SwiftFormat"
  url "https://github.com/bitmovin-engineering/SwiftFormat/archive/refs/tags/0.62.1-bitmovin.1.tar.gz"
  version "0.62.1-bitmovin.1"
  sha256 "1976cea13d9936e6ea33b55e2a74263fca1cafd7a5e936c120a917d2644c8035"
  license "MIT"
  head "https://github.com/bitmovin-engineering/SwiftFormat.git", branch: "develop"

  uses_from_macos "swift" => :build

  def install
    args = if OS.mac?
      ["--disable-sandbox"]
    else
      ["--static-swift-stdlib"]
    end
    system "swift", "build", *args, "--configuration", "release"
    bin.install ".build/release/swiftformat" => "swiftformat-bitmovin"
  end

  test do
    (testpath/"Source.swift").write "let ninja = 1\n"
    (testpath/".swiftlint.yml").write <<~YAML
      custom_rules:
        no_ninja:
          regex: ninja
          message: "Pirates are better than ninjas."
          severity: error
    YAML

    args = [
      "--lint", "--cache", "ignore",
      "--custom-rules", testpath/".swiftlint.yml",
      testpath/"Source.swift"
    ]
    output = shell_output("#{bin}/swiftformat-bitmovin #{args.join(" ")} 2>&1", 1)
    assert_match "(no_ninja) Pirates are better than ninjas.", output
  end
end
