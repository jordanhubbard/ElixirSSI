# The build tools are also available for installed development sessions.
FROM elixirssi-emulator:bookworm
COPY emulator/ /os/build/emulator/current/
COPY ssi-cm5 /os/scripts/ssi-cm5
COPY container.py /os/container.py
ENV SSI_FORWARD_BIND=0.0.0.0
WORKDIR /os
CMD ["python3", "/os/container.py"]
