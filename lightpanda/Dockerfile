FROM lightpanda/browser:nightly

# Default image runs lightpanda serve on 0.0.0.0:9222.
# Override to set a longer inactivity timeout (default is 10s, too short
# for multi-step automation tasks).
CMD ["/bin/lightpanda", "serve", \
     "--host", "0.0.0.0", \
     "--port", "9222", \
     "--timeout", "300", \
     "--log-level", "info"]
