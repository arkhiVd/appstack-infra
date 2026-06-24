# Build context = the app/ directory (so we can copy db/init).
#   docker build -f app/services/db-migrate/Dockerfile app
FROM postgres:16-alpine
COPY db/init/ /sql/
COPY services/db-migrate/run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
