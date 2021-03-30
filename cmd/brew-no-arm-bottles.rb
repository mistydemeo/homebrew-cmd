unbottled = Tap.new("homebrew", "core").formula_files.sort.map do |f|
  data = f.read
  if !data.include?("arm64_big_sur") && !data.include?("bottle :unneeded")
    f.basename.to_s.sub(/\.rb$/, "")
  end
end.compact

puts unbottled
