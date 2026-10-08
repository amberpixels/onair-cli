# frozen_string_literal: true

RSpec.describe Onair::Platform::Heroku do
  let(:config) { Onair::Config.new(platform: "heroku", app: "myapp", repo: nil, branch: "main", fetch: true) }
  let(:adapter) { described_class.new(config) }

  let(:deployed_sha) { sha_of("a") }
  let(:newer_sha) { sha_of("c") }

  let(:release) do
    { "version" => 1234, "description" => "Deploy aaaaaaa", "status" => "succeeded", "current" => true,
      "created_at" => "2026-06-12T10:00:00Z", "slug" => { "id" => "slug-1" } }
  end

  def succeeded_build(sha, at: "2026-06-12T09:00:00Z")
    { "status" => "succeeded", "source_blob" => { "version" => sha }, "created_at" => at }
  end

  def stub_releases(body: [release], status: 200)
    stub_request(:get, "https://api.heroku.com/apps/myapp/releases")
      .with(headers: { "Authorization" => "Bearer tok-123",
                       "Accept" => "application/vnd.heroku+json; version=3",
                       "Range" => "version ..; order=desc, max=10",
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

  def dyno(type: "web", state: "up", version: 1234, updated_at: "2026-06-12T10:01:00Z")
    { "type" => type, "state" => state, "release" => { "version" => version }, "updated_at" => updated_at }
  end

  def stub_dynos(body: [dyno], status: 200)
    stub_request(:get, "https://api.heroku.com/apps/myapp/dynos")
      .to_return(status: status, body: body.to_json)
  end

  def stub_preboot(enabled: false, status: 200)
    stub_request(:get, "https://api.heroku.com/apps/myapp/features/preboot")
      .to_return(status: status, body: { "name" => "preboot", "enabled" => enabled }.to_json)
  end

  before do
    allow(Onair::Auth::Netrc).to receive(:token).with("api.heroku.com").and_return("tok-123")
    stub_dynos
    stub_preboot
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

  describe "release phase" do
    let(:release_sha) { sha_of("b") }

    def newer_release(status:, slug_id: "slug-2", version: 1235)
      { "version" => version, "description" => "Deploy bbbbbbb", "status" => status, "current" => false,
        "created_at" => "2026-06-12T11:58:00Z", "slug" => { "id" => slug_id } }
    end

    def stub_slug2(commit: release_sha)
      stub_request(:get, "https://api.heroku.com/apps/myapp/slugs/slug-2")
        .to_return(status: 200, body: { "commit" => commit }.to_json)
    end

    it "keeps the current release as deployed while a newer one runs its release phase" do
      stub_releases(body: [newer_release(status: "pending"), release])
      stub_slug
      stub_slug2
      stub_builds(body: [succeeded_build(release_sha, at: "2026-06-12T11:55:00Z"), succeeded_build(deployed_sha)])

      snap = adapter.snapshot
      expect(snap.deployed.sha).to eq(deployed_sha)
      expect(snap.deployed.version).to eq(1234)
      expect(snap.release).to eq(Onair::Release.new(sha: release_sha, version: 1235, description: "Deploy bbbbbbb",
                                                    status: :pending,
                                                    started_at: Time.utc(2026, 6, 12, 11, 58, 0)))
    end

    it "surfaces a failed release without counting it as deployed" do
      stub_releases(body: [newer_release(status: "failed"), release])
      stub_slug
      stub_slug2
      stub_builds(body: [succeeded_build(release_sha)])

      snap = adapter.snapshot
      expect(snap.deployed.sha).to eq(deployed_sha)
      expect(snap.release.status).to eq(:failed)
    end

    it "reports only the newest release when a failed one was followed by another attempt" do
      stub_releases(body: [newer_release(status: "pending", slug_id: "slug-2", version: 1236),
                           newer_release(status: "failed", slug_id: "slug-3"), release])
      stub_slug
      stub_slug2
      stub_builds(body: [])

      snap = adapter.snapshot
      expect(snap.release.version).to eq(1236)
      expect(snap.release.status).to eq(:pending)
    end

    it "has no release once the newest one is running" do
      stub_releases
      stub_slug
      stub_builds(body: [])

      expect(adapter.snapshot.release).to be_nil
    end

    it "falls back to the newest succeeded release when no row is marked current" do
      stub_releases(body: [newer_release(status: "pending"), release.merge("current" => nil)])
      stub_slug
      stub_slug2
      stub_builds(body: [])

      snap = adapter.snapshot
      expect(snap.deployed.sha).to eq(deployed_sha)
      expect(snap.release.sha).to eq(release_sha)
    end

    it "reuses the running commit for a release on the same slug" do
      stub_releases(body: [newer_release(status: "pending", slug_id: "slug-1"), release])
      slug = stub_slug
      stub_builds(body: [])

      snap = adapter.snapshot
      expect(snap.release.sha).to eq(deployed_sha)
      expect(slug).to have_been_requested.once
    end

    it "drops the in-flight release when its commit cannot be resolved" do
      stub_releases(body: [newer_release(status: "pending"), release])
      stub_slug
      stub_request(:get, "https://api.heroku.com/apps/myapp/slugs/slug-2").to_return(status: 500)
      stub_builds(body: [])

      snap = adapter.snapshot
      expect(snap.deployed.sha).to eq(deployed_sha)
      expect(snap.release).to be_nil
    end

    it "errors when no release in the window has succeeded" do
      stub_releases(body: [newer_release(status: "failed")])
      stub_builds(body: [])

      expect { adapter.snapshot }.to raise_error(Onair::Error, /no succeeded release among the last 10/)
    end
  end

  describe "rollout" do
    before do
      stub_releases
      stub_slug
      stub_builds(body: [])
    end

    it "is complete when every dyno serves the running release" do
      stub_dynos(body: [dyno, dyno, dyno(type: "worker")])

      expect(adapter.snapshot.rollout).to eq(
        Onair::Rollout.new(version: 1234, overlap_until: nil, processes: [
                             Onair::ProcessRollout.new(type: "web", total: 2, up: 2, waiting: {}, previous: 0),
                             Onair::ProcessRollout.new(type: "worker", total: 1, up: 1, waiting: {}, previous: 0)
                           ])
      )
      expect(adapter.snapshot.rollout).to be_complete
    end

    it "counts dynos still starting, crashed, or on an older release" do
      stub_dynos(body: [dyno(type: "worker"), dyno, dyno(state: "starting"), dyno(state: "crashed"),
                        dyno(version: 1233)])

      rollout = adapter.snapshot.rollout
      expect(rollout.processes.map(&:type)).to eq(%w[web worker])
      expect(rollout.processes.first).to eq(
        Onair::ProcessRollout.new(type: "web", total: 4, up: 1, waiting: { "starting" => 1, "crashed" => 1 },
                                  previous: 1)
      )
      expect(rollout).not_to be_complete
    end

    it "counts an idle eco dyno on the running release as rolled out" do
      stub_dynos(body: [dyno(state: "idle")])

      expect(adapter.snapshot.rollout).to be_complete
    end

    it "ignores one-off dynos" do
      stub_dynos(body: [dyno, dyno(type: "run", state: "starting"), dyno(type: "scheduler", version: 1200),
                        dyno(type: "release", state: "starting")])

      expect(adapter.snapshot.rollout.processes.map(&:type)).to eq(["web"])
    end

    it "is nil when no formation dyno is listed" do
      stub_dynos(body: [dyno(type: "run")])

      expect(adapter.snapshot.rollout).to be_nil
    end

    it "estimates the preboot handoff from the newest web dyno once all web dynos are up" do
      stub_preboot(enabled: true)
      stub_dynos(body: [dyno(updated_at: "2026-06-12T11:58:00Z"), dyno(updated_at: "2026-06-12T11:59:00Z"),
                        dyno(type: "worker", updated_at: "2026-06-12T11:59:30Z")])

      expect(adapter.snapshot.rollout.overlap_until).to eq(Time.utc(2026, 6, 12, 12, 2, 0))
    end

    it "leaves the estimate out while old web dynos are still listed" do
      stub_preboot(enabled: true)
      stub_dynos(body: [dyno, dyno(version: 1233)])

      expect(adapter.snapshot.rollout.overlap_until).to be_nil
    end

    it "leaves the estimate out without preboot" do
      stub_dynos(body: [dyno(updated_at: "2026-06-12T11:59:00Z")])

      expect(adapter.snapshot.rollout.overlap_until).to be_nil
    end

    it "drops only the estimate when the preboot lookup fails" do
      stub_preboot(status: 500)

      rollout = adapter.snapshot.rollout
      expect(rollout.overlap_until).to be_nil
      expect(rollout.processes.first.total).to eq(1)
    end

    it "drops the rollout and keeps the rest of the report when the dynos call fails" do
      stub_dynos(status: 500)

      snap = adapter.snapshot
      expect(snap.rollout).to be_nil
      expect(snap.deployed.sha).to eq(deployed_sha)
    end
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
