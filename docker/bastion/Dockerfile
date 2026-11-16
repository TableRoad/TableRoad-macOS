# Minimal SSH bastion for integration tests: password + public-key auth, TCP forwarding on.
FROM alpine:3.20
RUN apk add --no-cache openssh \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh tableroad \
 && echo "tableroad:tableroad" | chpasswd \
 && mkdir -p /home/tableroad/.ssh
COPY authorized_keys /home/tableroad/.ssh/authorized_keys
COPY sshd_config /etc/ssh/sshd_config
RUN chown -R tableroad:tableroad /home/tableroad/.ssh \
 && chmod 700 /home/tableroad/.ssh && chmod 600 /home/tableroad/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
