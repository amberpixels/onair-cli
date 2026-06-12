# frozen_string_literal: true

RSpec.describe Onair::Platform::Heroku do
  let(:config) { Onair::Config.new(platform: "heroku", app: "myapp", repo: nil, branch: "main", fetch: true) }
  let(:adapter) { described_class.new(config) }

  let(:deployed_sha) { sha_of("a") }
  let(:newer_sha) { sha_of("c") }

  let(:release) do
    { "version" => 1234, "description" => "Deploy aaaaaaa",
      "created_at" => "2026-06-12T10:00:00Z", "slug" => { "id" => "slug-1" } }
  end

  def succeeded_build(sha, at: "2026-06-12T09:00:00Z")
    { "status" => "succeeded", "source_blob" => { "version" => sha }, "created_at" => at }
  end

  def stub_releases(body: [release], status: 200)
    stub_request(:get, "https://api.heroku.com/apps/myapp/releases")
      .with(headers: { "Authorization" => "Bearer tok-123",
                       "Accept" => "application/vnd.heroku+json; version=3",
                       "Range" => "version ..; order=desc, max=1",
                       "Accept-Encoding" => "identity" })
      .to_return(status: status, body: body.to_json)
  end

  def stub_slug(commit: deployed_sha)
    stub_request(:get, "https://api.heroku.com/apps/myapp/slugs/slug-1")
      .to_return(status: 200, body: { "commit" => commit }.to_json)
  end

  def stub_builds(body:, status: 200)
    stub_request(:get, "https://api.heroku.com/apps/myapp/builds")
      .with(headers: { "Range" => "created_at ..; order=desc, max=10" })
      .to_return(status: status, body: body.to_json)
  end

  before do
    allow(Onair::Auth::Netrc).to receive(:token).with("api.heroku.com").and_return("tok-123")
  end

  it "resolves the deployed sha from the running release's slug" do
    stub_releases
    stub_slug
    stub_builds(body: [succeeded_build(deployed_sha)])

    snap = adapter.snapshot
    expect(snap.deployed).to eq(Onair::Deployed.new(sha: deployed_sha, version: 1234,
                                                    description: "Deploy aaaaaaa",
                                                    deployed_at: Time.utc(2026, 6, 12, 10, 0, 0)))
    expect(snap.pending).to be_nil
    expect(snap.latest_built_sha).to eq(deployed_sha)
  end

  it "keeps the slug commit as deployed after a rollback (newest build is not what's running)" do
    stub_releases
    stub_slug
    stub_builds(body: [succeeded_build(newer_sha, at: "2026-06-12T11:00:00Z"), succeeded_build(deployed_sha)])

    snap = adapter.snapshot
    expect(snap.deployed.sha).to eq(deployed_sha)
    expect(snap.latest_built_sha).to eq(newer_sha)
    expect(snap.succeeded_shas).to eq([newer_sha, deployed_sha])
  end

  it "surfaces an in-flight build as pending" do
    pending_sha = sha_of("b")
    stub_releases
    stub_slug
    stub_builds(body: [
                  { "status" => "pending", "source_blob" => { "version" => pending_sha },
                    "created_at" => "2026-06-12T11:59:00Z" },
                  succeeded_build(deployed_sha)
                ])

    snap = adapter.snapshot
    expect(snap.pending).to eq(Onair::Pending.new(sha: pending_sha,
                                                  started_at: Time.utc(2026, 6, 12, 11, 59, 0)))
  end

  it "returns a nil deployed sha when the slug lookup fails" do
    stub_releases
    stub_request(:get, "https://api.heroku.com/apps/myapp/slugs/slug-1").to_return(status: 500)
    stub_builds(body: [succeeded_build(newer_sha)])

    snap = adapter.snapshot
    expect(snap.deployed.sha).to be_nil
    expect(snap.deployed.version).to eq(1234)
  end

  it "degrades gracefully when the builds call fails" do
    stub_releases
    stub_slug
    stub_builds(body: [], status: 500)

    snap = adapter.snapshot
    expect(snap.pending).to be_nil
    expect(snap.latest_built_sha).to be_nil
    expect(snap.succeeded_shas).to eq([])
  end

  it "is fatal when the releases call fails" do
    stub_releases(status: 500)
    stub_builds(body: [])

    expect { adapter.snapshot }.to raise_error(Onair::Error, /Heroku API returned 500/)
  end

  it "explains a rejected token" do
    stub_releases(status: 401)
    stub_builds(body: [])

    expect { adapter.snapshot }.to raise_error(Onair::Error, /401.*heroku login/)
  end

  it "explains an unknown app" do
    stub_releases(status: 404)
    stub_builds(body: [])

    expect { adapter.snapshot }.to raise_error(Onair::Error, "Heroku app not found: myapp")
  end

  it "turns timeouts into a friendly error" do
    stub_request(:get, "https://api.heroku.com/apps/myapp/releases").to_timeout
    stub_builds(body: [])

    expect { adapter.snapshot }.to raise_error(Onair::Error, /Heroku API request failed/)
  end

  describe "auth" do
    it "falls back to the Heroku CLI when netrc yields nothing" do
      allow(Onair::Auth::Netrc).to receive(:token).and_return(nil)
      allow(Onair::Auth::HerokuCli).to receive(:token).and_return("tok-123")
      stub_releases
      stub_slug
      stub_builds(body: [])

      expect(adapter.snapshot.deployed.sha).to eq(deployed_sha)
      expect(Onair::Auth::HerokuCli).to have_received(:token)
    end

    it "does not boot the CLI when netrc has a token" do
      allow(Onair::Auth::HerokuCli).to receive(:token)
      stub_releases
      stub_slug
      stub_builds(body: [])

      adapter.snapshot
      expect(Onair::Auth::HerokuCli).not_to have_received(:token)
    end

    it "errors with a login hint when no credentials exist anywhere" do
      allow(Onair::Auth::Netrc).to receive(:token).and_return(nil)
      allow(Onair::Auth::HerokuCli).to receive(:token).and_return(nil)

      expect { adapter.snapshot }.to raise_error(Onair::Error, /heroku login/)
    end
  end
end
