# frozen_string_literal: true

RSpec.describe Onair::Platform::GithubDeployments do
  let(:environment) { "production" }
  let(:config) do
    Onair::Config.new(platform: "github_deployments", app: nil, repo: nil, branch: "main", fetch: true,
      environment: environment)
  end
  let(:repo) { "acme/widgets" }
  let(:adapter) { described_class.new(config, repo: repo) }
  let(:api) { "https://api.github.com/repos/acme/widgets" }

  before { allow(Onair::Auth::GithubToken).to receive(:token).and_return("gh-tok") }

  def deployment(id, sha, created_at)
    {"id" => id, "sha" => sha, "environment" => environment, "created_at" => created_at}
  end

  def stub_deployments(rows, status: 200, query: {environment: environment, per_page: "10"})
    stub_request(:get, "#{api}/deployments")
      .with(query: query, headers: {"Authorization" => "Bearer gh-tok", "Accept" => "application/vnd.github+json",
                                    "X-GitHub-Api-Version" => "2022-11-28"})
      .to_return(status: status, body: rows.to_json)
  end

  def stub_status(id, state, at = "2026-06-12T10:00:00Z", status: 200)
    body = state ? [{"state" => state, "created_at" => at}] : []
    stub_request(:get, "#{api}/deployments/#{id}/statuses")
      .with(query: {per_page: "1"})
      .to_return(status: status, body: body.to_json)
  end

  it "reads the newest successful deployment as deployed" do
    stub_deployments([deployment(2, sha_of("b"), "2026-06-12T11:00:00Z"), deployment(1, sha_of("a"), "2026-06-12T09:00:00Z")])
    stub_status(2, "success", "2026-06-12T11:05:00Z")
    stub_status(1, "inactive")
    snap = adapter.snapshot
    expect(snap.deployed).to eq(Onair::Deployed.new(sha: sha_of("b"), version: nil, description: "deployment 2",
      deployed_at: Time.utc(2026, 6, 12, 11, 5, 0)))
    expect(snap.pending).to be_nil
    expect(snap.release).to be_nil
    expect(snap.rollout).to be_nil
    expect(snap.latest_built_sha).to eq(sha_of("b"))
    expect(snap.succeeded_shas).to eq([sha_of("b"), sha_of("a")])
  end

  it "shows an in-flight deployment above the deployed one as pending, with its commit" do
    stub_deployments([deployment(3, sha_of("c"), "2026-06-12T11:58:00Z"), deployment(2, sha_of("b"), "2026-06-12T11:00:00Z")])
    stub_status(3, "in_progress")
    stub_status(2, "success")
    expect(adapter.snapshot.pending).to eq(Onair::Pending.new(sha: sha_of("c"), started_at: Time.utc(2026, 6, 12, 11, 58, 0)))
  end

  it "shows a failed deployment above the deployed one as a failed release" do
    stub_deployments([deployment(3, sha_of("c"), "2026-06-12T11:58:00Z"), deployment(2, sha_of("b"), "2026-06-12T11:00:00Z")])
    stub_status(3, "error", "2026-06-12T11:59:00Z")
    stub_status(2, "success")
    expect(adapter.snapshot.release).to eq(Onair::Release.new(sha: sha_of("c"), version: nil,
      description: "deployment 3", status: :failed, started_at: Time.utc(2026, 6, 12, 11, 59, 0)))
  end

  it "ignores failures older than the deployed one" do
    stub_deployments([deployment(2, sha_of("b"), "2026-06-12T11:00:00Z"), deployment(1, sha_of("a"), "2026-06-12T09:00:00Z")])
    stub_status(2, "success")
    stub_status(1, "failure")
    expect(adapter.snapshot.release).to be_nil
  end

  it "skips a deployment with no status yet" do
    stub_deployments([deployment(3, sha_of("c"), "2026-06-12T11:58:00Z"), deployment(2, sha_of("b"), "2026-06-12T11:00:00Z")])
    stub_status(3, nil)
    stub_status(2, "success")
    snap = adapter.snapshot
    expect(snap.pending).to be_nil
    expect(snap.deployed.sha).to eq(sha_of("b"))
  end

  it "fails when a deployment above the newest success has an unreadable status" do
    stub_deployments([deployment(3, sha_of("c"), "2026-06-12T11:58:00Z"), deployment(2, sha_of("b"), "2026-06-12T11:00:00Z")])
    stub_status(3, "success", status: 500)
    stub_status(2, "success")
    expect { adapter.snapshot }.to raise_error(Onair::Error, /returned 500/)
  end

  it "drops an older deployment whose statuses call fails" do
    stub_deployments([deployment(2, sha_of("b"), "2026-06-12T11:00:00Z"), deployment(1, sha_of("a"), "2026-06-12T09:00:00Z")])
    stub_status(2, "success")
    stub_status(1, "inactive", status: 500)
    snap = adapter.snapshot
    expect(snap.deployed.sha).to eq(sha_of("b"))
    expect(snap.succeeded_shas).to eq([sha_of("b")])
  end

  it "returns no deploy when the environment has no deployments" do
    stub_deployments([])
    expect(adapter.snapshot).to eq(Onair::Snapshot.new(deployed: nil, pending: nil, release: nil,
      latest_built_sha: nil, succeeded_shas: [], rollout: nil))
  end

  it "shows a first deployment in flight with nothing deployed" do
    stub_deployments([deployment(1, sha_of("a"), "2026-06-12T09:00:00Z")])
    stub_status(1, "in_progress")
    snap = adapter.snapshot
    expect(snap.deployed).to be_nil
    expect(snap.pending).to eq(Onair::Pending.new(sha: sha_of("a"), started_at: Time.utc(2026, 6, 12, 9, 0, 0)))
  end

  it "shows the newest failure when no deployment in the window succeeded" do
    stub_deployments([deployment(2, sha_of("b"), "2026-06-12T11:00:00Z"), deployment(1, sha_of("a"), "2026-06-12T09:00:00Z")])
    stub_status(2, "failure", "2026-06-12T11:05:00Z")
    stub_status(1, "error")
    snap = adapter.snapshot
    expect(snap.deployed).to be_nil
    expect(snap.release.sha).to eq(sha_of("b"))
    expect(snap.succeeded_shas).to eq([])
  end

  it "fails when nothing succeeded and a status is unreadable" do
    stub_deployments([deployment(1, sha_of("a"), "2026-06-12T09:00:00Z")])
    stub_status(1, "success", status: 503)
    expect { adapter.snapshot }.to raise_error(Onair::Error, /returned 503/)
  end

  context "with an environment that needs encoding" do
    let(:environment) { "prod eu/1" }

    it "form-encodes it in the query" do
      stub = stub_request(:get, "#{api}/deployments?environment=prod+eu%2F1&per_page=10").to_return(body: "[]")
      adapter.snapshot
      expect(stub).to have_been_requested
    end
  end

  it "names the repo and environment in the header" do
    expect(adapter.display_name).to eq("GitHub")
    expect(adapter.target_label).to eq("acme/widgets (production)")
    expect(adapter.environment).to eq("production")
  end

  describe "errors" do
    it "hints at gh auth login on a rejected token" do
      stub_deployments([], status: 401)
      expect { adapter.snapshot }.to raise_error(Onair::Error, "GitHub rejected the token (401) - run `gh auth login`")
    end

    it "names the repo on a 404" do
      stub_deployments([], status: 404)
      expect { adapter.snapshot }.to raise_error(Onair::Error, /not found or not visible to this token: acme\/widgets/)
    end

    it "names the rate limit" do
      stub_request(:get, "#{api}/deployments").with(query: hash_including({}))
        .to_return(status: 403, headers: {"x-ratelimit-remaining" => "0"}, body: "{}")
      expect { adapter.snapshot }.to raise_error(Onair::Error, /rate limit/)
    end

    it "asks for a login when no token exists" do
      allow(Onair::Auth::GithubToken).to receive(:token).and_return(nil)
      expect { adapter.snapshot }.to raise_error(Onair::Error, "no GitHub token found - run `gh auth login`")
    end

    it "asks for a repo when none resolves" do
      expect { described_class.new(config, repo: nil) }.to raise_error(Onair::Error, /add `repo: owner\/name`/)
    end

    it "refuses a repo that is not owner/name" do
      ["acme/widgets/x", "../widgets", "acme/..", "acme"].each do |bad|
        expect { described_class.new(config, repo: bad) }.to raise_error(Onair::Error, /invalid GitHub repo/)
      end
    end
  end
end
