# frozen_string_literal: true

require_relative "git_source"

module CoreInvisibility
  # The child's side of GitSource: whether the folder Smith was loaded from
  # holds exactly a source's parts, checked against the ids its marker
  # names in the repository the parent hands over.
  module SourceFolder
    module_function

    # [kind, provenance] for a folder that holds exactly its source's parts
    # (the marker and the bundle's own files aside), each byte for byte,
    # with the Gemfile, Ruby the bundle runs, written by GitSource;
    # ["other", {}] for any other folder with a marker; nil without one.
    def of(root)
      return unless File.exist?(File.join(root, GitSource::MARKER))

      source = verified(root)
      source ? [source["source"], source.slice("built_on", "parts")] : ["other", {}]
    end

    def verified(root)
      source = marked(root)
      return unless source && own_gemfile?(root)

      expected = source["parts"].each_with_object({}) { |(part, id), all| all.merge!(listing(part, id)) }
      files = files_in(root)
      source if files.sort == expected.keys.sort && hashed(root, files) == files.map { expected.fetch(_1) }
    rescue GitSource::Refused
      nil
    end

    def files_in(root)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { File.file?(File.join(root, _1)) } - GitSource::OWN
    end

    def own_gemfile?(root)
      gemfile = File.join(root, GitSource::GEMFILE)
      File.file?(gemfile) && File.read(gemfile) == GitSource::GEMFILE_TEXT
    end

    def marked(root)
      source = JSON.parse(File.read(File.join(root, GitSource::MARKER)))
      source if GitSource.named?(source)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # { path => blob id } for every file a part holds.
    def listing(part, id)
      return { part => id } if GitSource.git("cat-file", "-t", id).strip == "blob"

      GitSource.git("ls-tree", "-r", "-z", "--full-tree", id).split("\0").to_h do |entry|
        meta, path = entry.split("\t", 2)
        ["#{part}/#{path}", meta.split.last]
      end
    end

    # The blob ids of the files as they are, written nowhere.
    def hashed(root, files)
      GitSource.git("hash-object", "--no-filters", "--stdin-paths", input: files.map { File.join(root, _1) }.join("\n"))
               .split
    end
  end
end
