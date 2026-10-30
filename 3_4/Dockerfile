FROM docker:git

COPY builder.sh /builder.sh
RUN chmod +x /builder.sh

ENTRYPOINT ["/builder.sh"]
