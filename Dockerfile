FROM ocaml/opam2:4.06

# UPDATE OPAM
RUN opam update

# ADD THIS SOURCE DIR TO THE DOCKRE IMAGE
ADD ./ /src/

# MAKE SURE THE 'opam' USER OWNS /src
RUN sudo chown -R opam:opam /src

# STAY IN /src/mirage WHILE WE BUILD
WORKDIR /src/mirage

# PIN CALDAV
RUN opam pin caldav /src --no-action

# INSTALL MIRAGE CLI NATIVE DEPENDENCIES (IF ANY)
RUN opam depext mirage=3.5.1

# INSTALL MIRAGE CLI
RUN opam install mirage=3.5.1

# CONFIGURE MIRAGE UNIKERNEL
RUN opam exec mirage -- configure

# PIN MIRAGE UNIKERNEL
RUN opam pin mirage-unikernel-caldav-unix /src/mirage --no-action

# INSTALL CALDAV & MIRAGE UNIKERNEL NATIVE DEPENDENCIES (IF ANY)
RUN opam depext caldav mirage-unikernel-caldav-unix

# INSTALL CALDAV & MIRAGE OPAM DEPENDENCIES
RUN opam install caldav mirage-unikernel-caldav-unix --deps-only

# INSTALL CALDAV
RUN opam install caldav

# BUILD THE MIRAGE UNIKERNEL
RUN opam exec mirage -- build
