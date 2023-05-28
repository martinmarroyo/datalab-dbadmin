FROM dpage/pgadmin4:7.1

# Add DataLab-DB connection info
COPY entrypoint.sh /
COPY datalab-connection.json /pgadmin4/
# Set necessary env variables
ENV PGADMIN_DEFAULT_EMAIL=admin@datalab.com
ENV PGADMIN_DEFAULT_PASSWORD=datalab
ENV PGADMIN_LISTEN_PORT=80
