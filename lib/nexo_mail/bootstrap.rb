# frozen_string_literal: true

module NexoMail
  # First-run provisioning: create the XDG config/state directories and seed the
  # default config, skills, and prompts README. Idempotent — existing files are
  # never overwritten (so user edits survive).
  module Bootstrap
    module_function

    def ensure!(out: $stderr)
      FileUtils.mkdir_p(File.dirname(Config.config_file))
      seed_file(Config.config_file, data("config.example.toml"), out: out,
        notice: "Wrote default config to #{Config.config_file} — add a model under [[models]] to get started.")

      FileUtils.mkdir_p(Config.sandbox_dir)
      seed_skills
      seed_prompts
    end

    def seed_skills
      FileUtils.mkdir_p(Config.skills_dir)
      gem_skills = data("skills")
      Dir.children(gem_skills).each do |name|
        dest = File.join(Config.skills_dir, name)
        FileUtils.cp_r(File.join(gem_skills, name), dest) unless File.exist?(dest)
      end
    end

    def seed_prompts
      FileUtils.mkdir_p(Config.prompts_dir)
      seed_file(File.join(Config.prompts_dir, "README.md"), data("prompts", "README.md"))
    end

    # Copy src → dest only if dest is absent; optionally print a one-line notice.
    def seed_file(dest, src, notice: nil, out: $stderr)
      return if File.exist?(dest)

      FileUtils.cp(src, dest)
      out.puts(notice) if notice
    end

    def data(*parts) = File.join(NexoMail::DATA_DIR, *parts)
  end
end
