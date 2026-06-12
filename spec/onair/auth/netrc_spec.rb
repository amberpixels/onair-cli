# frozen_string_literal: true

require "tmpdir"

RSpec.describe Onair::Auth::Netrc do
  def write_netrc(content)
    path = File.join(@dir, ".netrc")
    File.write(path, content)
    path
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  it "reads a same-line entry" do
    path = write_netrc("machine api.heroku.com login me@example.com password secret-token\n")
    expect(described_class.token("api.heroku.com", path: path)).to eq("secret-token")
  end

  it "reads a multi-line entry" do
    path = write_netrc(<<~NETRC)
      machine api.heroku.com
        login me@example.com
        password secret-token
    NETRC
    expect(described_class.token("api.heroku.com", path: path)).to eq("secret-token")
  end

  it "picks the right machine among several" do
    path = write_netrc(<<~NETRC)
      machine git.heroku.com
        login me@example.com
        password git-token
      machine api.heroku.com
        login me@example.com
        password api-token
    NETRC
    expect(described_class.token("api.heroku.com", path: path)).to eq("api-token")
  end

  it "does not read past the next machine entry" do
    path = write_netrc(<<~NETRC)
      machine api.heroku.com
        login me@example.com
      machine other.example.com
        password not-yours
    NETRC
    expect(described_class.token("api.heroku.com", path: path)).to be_nil
  end

  it "returns nil when the machine is missing" do
    path = write_netrc("machine example.com login a password b\n")
    expect(described_class.token("api.heroku.com", path: path)).to be_nil
  end

  it "returns nil when the file does not exist" do
    expect(described_class.token("api.heroku.com", path: File.join(@dir, "missing"))).to be_nil
  end
end
