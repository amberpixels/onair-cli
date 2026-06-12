# frozen_string_literal: true

RSpec.describe Onair::RemoteHead do
  let(:api_sha) { sha_of("a") }
  let(:ls_remote_sha) { sha_of("f") }
  let(:git) { FakeGit.new(remote_head: ls_remote_sha) }

  def resolve(repo: "acme/widgets", branch: "main")
    described_class.resolve(git: git, branch: branch, repo: repo)
  end

  def stub_ref(repo: "acme/widgets", branch: "main", sha: api_sha, status: 200)
    body = { "ref" => "refs/heads/#{branch}", "object" => { "sha" => sha, "type" => "commit" } }
    stub_request(:get, "https://api.github.com/repos/#{repo}/git/ref/heads/#{branch}")
      .with(headers: { "Authorization" => "Bearer gh-tok", "Accept" => "application/vnd.github+json" })
      .to_return(status: status, body: body.to_json)
  end

  context "with an ambient token" do
    before { allow(Onair::Auth::GithubToken).to receive(:token).and_return("gh-tok") }

    it "answers from the GitHub API" do
      stub_ref
      expect(resolve).to eq(api_sha)
    end

    it "resolves non-default branches" do
      stub_ref(branch: "develop")
      expect(resolve(branch: "develop")).to eq(api_sha)
    end

    it "falls back to ls-remote when the API errors" do
      stub_ref(status: 404)
      expect(resolve).to eq(ls_remote_sha)
    end

    it "falls back to ls-remote when the API times out" do
      stub_request(:get, "https://api.github.com/repos/acme/widgets/git/ref/heads/main").to_timeout
      expect(resolve).to eq(ls_remote_sha)
    end

    it "falls back to ls-remote when the API returns a malformed sha" do
      stub_ref(sha: "not-a-sha")
      expect(resolve).to eq(ls_remote_sha)
    end
  end

  it "skips the API entirely when no repo is known" do
    allow(Onair::Auth::GithubToken).to receive(:token)
    expect(resolve(repo: nil)).to eq(ls_remote_sha)
    expect(Onair::Auth::GithubToken).not_to have_received(:token)
  end

  it "falls back to ls-remote when no token is available" do
    allow(Onair::Auth::GithubToken).to receive(:token).and_return(nil)
    expect(resolve).to eq(ls_remote_sha)
  end
end
