{ lib
, runCommand
, remarshal
, fetchurl
, ...
}:

with lib;
let
  splitVersion = name: splitString "@" (head (splitString "(" name));
  getVersion = name: last (splitVersion name);
  withoutVersion = name: concatStringsSep "@" (init (splitVersion name));
  gitTarball = n: v:
    let
      repo =
        if ((v.resolution.type or "") == "git")
        then
          fetchGit
            {
              url = v.resolution.repo;
              rev = v.resolution.commit;
              shallow = true;
            }
        else
          let
            split = splitString "/" n;
          in
          fetchGit {
            url = "https://${concatStringsSep "/" (take 3 split)}.git";
            rev = head (splitString "(" (builtins.elemAt split 3));
            shallow = true;
          };
    in
    # runCommand (last (init (traceValSeq (splitString "/" (traceValSeq (withoutVersion (traceValSeq n))))))) { } ''
    runCommand "${last (init (splitString "/" (head (splitString "(" n))))}.tgz" { } ''
      tar -czf $out -C ${repo} .
    '';
  urlTarball = { url, extraIntegritySha256 }:
    fetchurl { inherit url; sha256 = extraIntegritySha256.${url}; };
in
rec {

  parseLockfile = lockfile: builtins.fromJSON (readFile (runCommand "toJSON" { } "${remarshal}/bin/yaml2json ${lockfile} $out"));

  dependencyTarballs = { registry, lockfile, extraIntegritySha256 }:
    unique (
      mapAttrsToList
        (n: v:
          if hasPrefix "/" n then # fetch from registry
            let
              name = withoutVersion n;
              baseName = last (splitString "/" (withoutVersion n));
              version = getVersion n;
            in
            fetchurl (
              {
                url = v.resolution.tarball or "${registry}/${name}/-/${baseName}-${version}.tgz";
              } // (
                if hasPrefix "sha1-" v.resolution.integrity then
                  { sha1 = v.resolution.integrity; }
                else
                  { sha512 = v.resolution.integrity; }
              )
            )
          else if hasPrefix "@" n then # fetch from url
            urlTarball { url = v.resolution.tarball; inherit extraIntegritySha256; }
          else # fetch from git
            gitTarball n v
        )
        (parseLockfile lockfile).packages
    );

  patchLockfile = { pnpmLockYaml, extraIntegritySha256 }:
    let
      orig = parseLockfile pnpmLockYaml;
    in
    orig // {
      packages = mapAttrs
        (n: v:
          if hasPrefix "/" n
          then v
          else if hasPrefix "@" n
          then v // { resolution.tarball = "file:${urlTarball { inherit extraIntegritySha256; url = v.resolution.tarball; }}"; }
          else v // {
            resolution.tarball = "file:${gitTarball n v}";
          }
        )
        orig.packages;

    };

}
