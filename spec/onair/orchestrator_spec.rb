# frozen_string_literal: true

RSpec.describe Onair::Orchestrator do
  let(:config) do
    Onair::Config.new(platform: "heroku", app: "myapp", repo: nil, branch: "main", fetch: true)
  end

  let(:adapter) do
    snap = snapshot(deployed: deployed(sha: sha_of("a")))
    Class.new do
      define_method(:snapshot) { snap }
    end.new
  end

  it "assembles a report from the adapter snapshot and the remote head" do
    git = FakeGit.new(commits: { sha_of("a") => commit_info }, remote_head: sha_of("a"))
    report = described_class.new(config: config, adapter: adapter, git: git).run
    expect(report.snapshot.deployed.sha).to eq(sha_of("a"))
    expect(report.delta).to eq(:current)
  end

  it "fetches once when a needed sha is missing locally" do
    git = FakeGit.new(remote_head: sha_of("f"))
    described_class.new(config: config, adapter: adapter, git: git).run
    expect(git.fetch_count).to eq(1)
  end

  it "does not fetch when all shas are present" do
    git = FakeGit.new(commits: { sha_of("a") => commit_info }, remote_head: sha_of("a"))
    described_class.new(config: config, adapter: adapter, git: git).run
    expect(git.fetch_count).to eq(0)
  end

  it "propagates adapter failures" do
    failing = Class.new do
      def snapshot
        raise Onair::Error, "boom"
      end
    end.new
    orchestrator = described_class.new(config: config, adapter: failing, git: FakeGit.new)
    expect { orchestrator.run }.to raise_error(Onair::Error, "boom")
  end
end
