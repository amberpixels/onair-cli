# frozen_string_literal: true

require "open3"

RSpec.describe Onair::Auth::GithubToken do
  it "prefers GH_TOKEN" do
    expect(described_class.token(env: { "GH_TOKEN" => "from-gh", "GITHUB_TOKEN" => "from-github" }))
      .to eq("from-gh")
  end

  it "falls back to GITHUB_TOKEN" do
    expect(described_class.token(env: { "GITHUB_TOKEN" => "from-github" })).to eq("from-github")
  end

  it "ignores empty env values" do
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).with("gh", "auth", "token").and_return(["cli-tok\n", "", status])
    expect(described_class.token(env: { "GH_TOKEN" => "" })).to eq("cli-tok")
  end

  it "asks the gh CLI when env vars are unset" do
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).with("gh", "auth", "token").and_return(["cli-tok\n", "", status])
    expect(described_class.token(env: {})).to eq("cli-tok")
  end

  it "is nil when gh is not logged in" do
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3).with("gh", "auth", "token").and_return(["", "no token", status])
    expect(described_class.token(env: {})).to be_nil
  end

  it "is nil when gh is not installed" do
    allow(Open3).to receive(:capture3).with("gh", "auth", "token").and_raise(Errno::ENOENT)
    expect(described_class.token(env: {})).to be_nil
  end
end
