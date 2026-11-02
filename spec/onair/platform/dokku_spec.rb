# frozen_string_literal: true

RSpec.describe Onair::Platform::Dokku do
  let(:host) { "my-dokku" }
  let(:config) do
    Onair::Config.new(platform: "dokku", app: "myapp", repo: nil, branch: "main", fetch: true, host: host)
  end
  let(:adapter) { described_class.new(config) }
  let(:deployed_sha) { sha_of("a") }

  # Fixtures use the keys Dokku 0.38 prints for `--format json`.
  let(:apps_report) do
    {"deploy-source" => "git-push", "deploy-source-metadata" => deployed_sha,
     "app-deploy-source" => "git-push", "app-deploy-source-metadata" => deployed_sha, "locked" => "false"}
  end
  let(:git_report) { {"last-updated-at" => "1781258400", "sha" => sha_of("e"), "deploy-branch" => "main"} }
  let(:ps_report) do
    {"deployed" => "true", "running" => "true", "processes" => "3",
     "status-web-1" => "running (CID: 0123456789a)", "status-web-2" => "running (CID: 0123456789b)",
     "status-worker-1" => "running (CID: 0123456789c)"}
  end
  let(:checks_report) { {"computed-wait-to-retire" => "60", "wait-to-retire" => ""} }
  let(:builds) { [build("7", "succeeded", started: "2026-06-12T10:00:00.123456Z", finished: "2026-06-12T10:00:40Z")] }

  def build(id, status, started:, finished: nil)
    {"id" => id, "app" => "myapp", "kind" => "build", "pid" => 100, "started_at" => started,
     "finished_at" => finished, "status" => (status == "abandoned") ? "running" : status,
     "display_status" => status, "source" => "git-hook", "duration" => "40s", "log_path" => "/x"}.compact
  end

  def reply(body, stderr: "", exit: 0)
    [body.is_a?(String) ? body : body.to_json, stderr, instance_double(Process::Status, success?: exit.zero?, exitstatus: exit)]
  end

  def stub_dokku(overrides = {})
    replies = {
      "apps:report" => reply(apps_report), "git:report" => reply(git_report),
      "builds:list" => reply(builds), "ps:report" => reply(ps_report), "checks:report" => reply(checks_report)
    }.merge(overrides)
    allow(adapter).to receive(:run) do |argv|
      expect(argv).to eq(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3", host, argv[10], "myapp", "--format", "json"])
      replies.fetch(argv[10])
    end
  end

  it "resolves the deployed sha from git-push deploy metadata, never git:report's sha" do
    stub_dokku
    snap = adapter.snapshot
    expect(snap.deployed).to eq(Onair::Deployed.new(sha: deployed_sha, version: nil,
      description: "deploy source: git-push", deployed_at: Time.at(1_781_258_400).utc))
    expect(snap.pending).to be_nil
    expect(snap.release).to be_nil
    expect(snap.latest_built_sha).to be_nil
    expect(snap.succeeded_shas).to eq([])
  end

  it "leaves the sha nil when the app was not deployed by a git push" do
    apps_report.merge!("deploy-source" => "git:from-image", "deploy-source-metadata" => "nginx:latest")
    stub_dokku
    expect(adapter.snapshot.deployed.sha).to be_nil
    expect(adapter.snapshot.deployed.description).to eq("deploy source: git:from-image")
  end

  it "raises when nothing has been deployed" do
    apps_report.merge!("deploy-source" => "", "deploy-source-metadata" => "")
    stub_dokku
    expect { adapter.snapshot }.to raise_error(Onair::Error, "nothing deployed yet for app myapp")
  end

  it "reports a running build as a commitless pending row" do
    builds.unshift(build("8", "running", started: "2026-06-12T11:59:00Z"))
    stub_dokku
    expect(adapter.snapshot.pending).to eq(Onair::Pending.new(sha: nil, build_id: "8",
      started_at: Time.utc(2026, 6, 12, 11, 59, 0)))
  end

  it "ignores an abandoned build" do
    builds.unshift(build("8", "abandoned", started: "2026-06-12T11:59:00Z"))
    stub_dokku
    expect(adapter.snapshot.pending).to be_nil
  end

  it "reports a failed build newer than the last success" do
    builds.unshift(build("8", "failed", started: "2026-06-12T11:50:00Z", finished: "2026-06-12T11:51:00Z"))
    stub_dokku
    expect(adapter.snapshot.release).to eq(Onair::Release.new(sha: nil, version: nil, description: "build 8",
      status: :failed, started_at: Time.utc(2026, 6, 12, 11, 51, 0)))
  end

  it "ignores a failed build older than the last success" do
    builds.push(build("6", "failed", started: "2026-06-12T09:00:00Z", finished: "2026-06-12T09:01:00Z"))
    stub_dokku
    expect(adapter.snapshot.release).to be_nil
  end

  it "aggregates containers per process type, web first" do
    ps_report["status-worker-2"] = "restarting (CID: 0123456789d)"
    stub_dokku
    rollout = adapter.snapshot.rollout
    expect(rollout.version).to be_nil
    expect(rollout.overlap_note).to eq("retiring: previous containers may still serve")
    expect(rollout.processes).to eq([
      Onair::ProcessRollout.new(type: "web", total: 2, up: 2, waiting: {}, previous: 0),
      Onair::ProcessRollout.new(type: "worker", total: 2, up: 1, waiting: {"restarting" => 1}, previous: 0)
    ])
    expect(rollout.overlap_until).to be_nil
  end

  it "estimates the retire window from the newest success and wait-to-retire" do
    checks_report["computed-wait-to-retire"] = "90"
    stub_dokku
    expect(adapter.snapshot.rollout.overlap_until).to eq(Time.utc(2026, 6, 12, 10, 2, 10))
  end

  it "keeps process types that contain dashes" do
    ps_report.replace("status-release-worker-1" => "running (CID: 0123456789e)")
    stub_dokku
    expect(adapter.snapshot.rollout.processes.map(&:type)).to eq(["release-worker"])
  end

  it "parses stdout only, ignoring warnings on stderr" do
    stub_dokku("builds:list" => reply(builds, stderr: " !     Skipping unreadable build record 3\n"))
    expect(adapter.snapshot.deployed.sha).to eq(deployed_sha)
  end

  it "degrades when the builds, ps, checks or git reports fail" do
    failure = reply("", stderr: " !     boom\n", exit: 1)
    stub_dokku("builds:list" => failure, "ps:report" => failure, "checks:report" => failure,
      "git:report" => failure)
    snap = adapter.snapshot
    expect(snap.deployed.sha).to eq(deployed_sha)
    expect(snap.deployed.deployed_at).to be_nil
    expect(snap.pending).to be_nil
    expect(snap.rollout).to be_nil
  end

  it "turns a BatchMode key refusal into an ssh-add hint" do
    refused = reply("", stderr: "dokku@my-dokku: Permission denied (publickey).\n", exit: 255)
    stub_dokku("apps:report" => refused)
    expect { adapter.snapshot }
      .to raise_error(Onair::Error, "SSH to my-dokku was refused - load the key with `ssh-add`")
  end

  it "names Dokku's own error when a command fails" do
    stub_dokku("apps:report" => reply("", stderr: " !     App myapp does not exist\n", exit: 1))
    expect { adapter.snapshot }
      .to raise_error(Onair::Error, "dokku apps:report failed on my-dokku: App myapp does not exist")
  end

  it "names an unreachable host without the ssh-add hint" do
    stub_dokku("apps:report" => reply("", stderr: "ssh: connect to host my-dokku port 22: Connection refused\n",
      exit: 255))
    expect { adapter.snapshot }
      .to raise_error(Onair::Error, "could not reach my-dokku over SSH: ssh: connect to host my-dokku port 22: " \
        "Connection refused")
  end

  it "reports a missing ssh client in one line" do
    allow(adapter).to receive(:run).and_raise(Errno::ENOENT)
    expect { adapter.snapshot }.to raise_error(Onair::Error, /ssh not found/)
  end

  it "reports invalid JSON on stdout" do
    stub_dokku("apps:report" => reply("not json"))
    expect { adapter.snapshot }.to raise_error(Onair::Error, "Dokku returned invalid JSON for apps:report")
  end

  it "reports a command that outlived the timeout" do
    stub_dokku("apps:report" => ["", "", nil])
    expect { adapter.snapshot }.to raise_error(Onair::Error, "dokku apps:report timed out on my-dokku")
  end

  it "reports a failed build when no succeeded build is listed" do
    builds.replace([build("8", "failed", started: "2026-06-12T11:50:00Z", finished: "2026-06-12T11:51:00Z")])
    stub_dokku
    expect(adapter.snapshot.release.description).to eq("build 8")
  end

  describe "running a command" do
    it "returns stdout, stderr and the exit status" do
      out, err, status = adapter.send(:run, ["sh", "-c", "echo out; echo err >&2; exit 3"])
      expect([out, err, status.exitstatus]).to eq(["out\n", "err\n", 3])
    end

    it "kills a command that outlives the timeout" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _, _, status = adapter.send(:run, ["sleep", "5"], timeout: 0.2)
      expect(status).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end
  end

  context "with an invalid app name" do
    let(:config) do
      Onair::Config.new(platform: "dokku", app: "My_App", repo: nil, branch: "main", fetch: true, host: host)
    end

    it "refuses it" do
      expect { adapter.snapshot }.to raise_error(Onair::Error, /invalid Dokku app name/)
    end
  end

  context "without a host" do
    let(:host) { nil }

    it "asks for one" do
      expect { adapter.snapshot }.to raise_error(Onair::Error, /no host configured/)
    end
  end

  context "with a host that would read as an ssh option" do
    let(:host) { "-oProxyCommand=evil" }

    it "refuses it" do
      expect { adapter.snapshot }.to raise_error(Onair::Error, /invalid Dokku host/)
    end
  end
end
