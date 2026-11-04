# The sandbox (IS-Atlas-94) is macOS's: its tests run where there is one, and where there
# is none, the test that nothing runs without it.
sandbox? = File.exists?("/usr/bin/sandbox-exec")
ExUnit.start(exclude: if(sandbox?, do: [:no_sandbox], else: [:sandbox]))
