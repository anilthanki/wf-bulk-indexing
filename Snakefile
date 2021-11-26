import os
from pathlib import Path
import glob
import re
# atom: set grammar=python:

TYPES = ['annotations', 'array_designs', 'go', 'interpro', 'reactome', 'mirbase']
bioentities_directories_to_stage = set()
staging_files = set()

print(f"ENS version: {config['ens_version']}")
print(f"ENS GN version: {config['eg_version']}")

def get_version(source):
    if source == 'ensembl' or source == "ens":
        return f"{config['ens_version']}_{config['eg_version']}"
    else:
        return config['wbsp_version']

def get_bioentities_directories_to_stage():
    """
    List all the directories from the main atlas bioentities that need to be staged
    to be able to run this in a per organism level.

    The web application code running these processes descides on the species to
    run based on the files it find in the BIOENTITIES path given.

    This is the structure of directories that we aim to match
    annotations_ensembl_104_51*  annotations_wbps_15      go_ens104_51*
    array_designs_104_51_15*     ensembl_104_51*          reactome_ens104_51*  wbps_15*
    """
    global bioentities_directories_to_stage
    global TYPES
    species = config['species']
    print(f"Lenght of set {len(bioentities_directories_to_stage)}")
    if bioentities_directories_to_stage:
        return bioentities_directories_to_stage
    dirs=set()
    prefix=f"{config['bioentities_source']}"
    for type in TYPES:
        dir = f"{prefix}/{type}"
        if os.path.isdir(dir):
            print(f"{dir} exists")
            dirs.add(dir)

    bioentities_directories_to_stage = dirs
    return bioentities_directories_to_stage


def get_destination_dir(dir):
    prefix='bioentity_properties'
    return f"{prefix}/{os.path.basename(dir)}"

def get_all_staging_files():
    global staging_files
    if staging_files:
        return staging_files
    species = config['species']
    results = []
    source_dirs = get_bioentities_directories_to_stage()
    for sdir in source_dirs:
        dest = get_destination_dir(sdir)
        print(f"Looking at {sdir} with destination {dest}")
        if dest.endswith("go") or dest.endswith('interpro'):
            files = [os.path.basename(f) for f in glob.glob(f"{sdir}/*.tsv")]
        else:
            files = [os.path.basename(f) for f in glob.glob(f"{sdir}/{species}*.tsv")]
            # We have cases where the files are buried one directory below :-(
            files.extend([os.path.basename(f) for f in glob.glob(f"{sdir}/*/{species}*.tsv")])
        results.extend([f"{dest}/{f}" for f in files])

    staging_files.update(results)
    return staging_files

wbps_annotations_re = re.compile(r"annotations.*wbps")
ens_annotations_re = re.compile(r"annotations.*ens")
array_designs_re = re.compile(r"array_designs.*\.(A-[A-Z]{4}-[0-9]+)\.tsv")

def get_jsonl_label(input):
    global wbps_annotations_re
    global ens_annotations_re
    global array_designs_re

    if "reactome" in input:
        return "reactome"
    if "mirbase" in input:
        return "mature_mirna"
    if wbps_annotations_re.search(input):
        return "wbpsgene"
    if ens_annotations_re.search(input):
        return "ensgene"
    m_array = array_designs_re.search(input)
    if m_array:
        return m_array.group(1)


def get_jsonl_paths():
    inputs_for_jsonl = get_all_staging_files()
    jsonls = set()
    for input in inputs_for_jsonl:
        json_label = get_jsonl_label(input)
        if json_label:
            jsonls.add(f"{config['output_dir']}/{config['species']}.{json_label}.jsonl")
    print(f"Number of JSONLs expected: {len(jsonls)}")
    return jsonls


rule stage_files_for_species:
    log: "staging.log"
    input:
        directories=get_bioentities_directories_to_stage()
    output:
        staged_files=get_all_staging_files()
    params:
        species=config['species']
    run:
        rsync_options = '-a --delete'
        for dir in input.directories:
            dest = get_destination_dir(dir)
            # even if there is no content, the web app context will expect the dir.
            Path(dest).mkdir(parents=True, exist_ok=True)
            if dest.endswith("go") or dest.endswith("interpro"):
                call = f"rsync {rsync_options} --include=*.tsv  --exclude=* {dir}/* {dest}"
            elif not glob.glob(f"{dir}/{params.species}*.tsv") and not glob.glob(f"{dir}/*/{params.species}*.tsv"):
                print(f"Skipping {dir} for {params.species}")
                continue
            elif dest.endswith('annotations') or dest.endswith('array_designs'):
                # some directories which are not "go" will not have anything for our species
                call = f"rsync {rsync_options} {dir}/**/{params.species}*.tsv {dest}"
            elif dest.endswith('reactome') or dest.endswith('mirbase'):
                call = f"rsync {rsync_options} {dir}/{params.species}*.tsv {dest}"


            print(f"Calling {call}")
            command = f"""
                      exec &> "{log}"
                      mkdir -p {dest}
                      {call}
                      """
            shell(command)
            print(f"{dir} staged")


rule run_bioentities_JSONL_creation:
    container: "docker://quay.io/ebigxa/atlas-index-base:1.0"
    log: "create_bioentities_jsonl.log"
    input:
        staged_files=rules.stage_files_for_species.output.staged_files
    params:
        bioentities="./",
        output_dir=config['output_dir'],
        atlas_env_file=config['atlas_env_file'],
        experiment_files="./experiment_files",
        atlas_exps=config['atlas_exps'],
        web_app_context=config['web_app_context'],
        exp_design_path=config['atlas_exp_design']
    resources:
        mem_mb=16000
    output:
        jsonl=get_jsonl_paths()
    shell:
        """
        set -e # snakemake on the cluster doesn't stop on error when --keep-going is set
        exec &> "{log}"
        source {params.atlas_env_file}

        export BIOENTITIES={params.bioentities}
        export output_dir={params.output_dir}
        export EXPERIMENT_FILES={params.experiment_files}
        export BIOENTITIES_JSONL_PATH={params.output_dir}
        export server_port=8081 #fake

        mkdir -p {params.experiment_files}
        mkdir -p {params.output_dir}
        rm -f {params.experiment_files}/magetab
        rm -f {params.experiment_files}/expdesign
        ln -sf {params.atlas_exps} {params.experiment_files}/magetab
        ln -sf {params.exp_design_path} {params.experiment_files}/expdesign
        ln -sf {params.web_app_context}/species-properties.json {params.experiment_files}/species-properties.json
        ln -sf {params.web_app_context}/release-metadata.json {params.experiment_files}/release-metadata.json

        if [ -f /bin/micromamba ]; then
            eval "$(/bin/micromamba shell hook -s bash)"
            micromamba activate "$ENV_NAME"
        fi

        {workflow.basedir}/index-bioentities/bin/create_bioentities_jsonl.sh
        """

rule delete_species_bioentities_index:
    container:
        "docker://quay.io/ebigxa/atlas-index-base:1.0"
    log: "delete_species_bioentities_index.log"
    params:
        atlas_env_file=config['atlas_env_file'],
        species=config['species']
    input:
        jsonl=rules.run_bioentities_JSONL_creation.output.jsonl
    output:
        deleted=touch(f"{config['species']}.index.deleted")
    shell:
        """
        set -e # snakemake on the cluster doesn't stop on error when --keep-going is set
        exec &> "{log}"
        source {params.atlas_env_file}
        export SPECIES={params.species}

        if [ -f /bin/micromamba ]; then
            eval "$(/bin/micromamba shell hook -s bash)"
            micromamba activate "$ENV_NAME"
        fi

        {workflow.basedir}/index-bioentities/bin/delete_bioentities_species.sh
        """

rule load_species_into_bioentities_index:
    container:
        "docker://quay.io/ebigxa/atlas-index-base:1.0"
    log: "load_species_into_bioentities_index.log"
    params:
        bioentities="./",
        output_dir=config['output_dir'],
        atlas_env_file=config['atlas_env_file'],
        experiment_files="./experiment_files",
        atlas_exps=config['atlas_exps'],
        exp_design_path=config['atlas_exp_design']
        species=config['species']
    input:
        jsonl=rules.run_bioentities_JSONL_creation.output.jsonl,
        deleted_confirmation=rules.delete_species_bioentities_index.output.deleted
    output:
        loaded=touch(f"{config['species']}.index.loaded")
    shell:
        """
        set -e # snakemake on the cluster doesn't stop on error when --keep-going is set
        exec &> "{log}"
        source {params.atlas_env_file}

        export BIOENTITIES={params.bioentities}
        export EXPERIMENT_FILES={params.experiment_files}
        export BIOENTITIES_JSONL_PATH={params.output_dir}
        export SPECIES={params.species}
        export server_port=8081 #fake

        if [ -f /bin/micromamba ]; then
            eval "$(/bin/micromamba shell hook -s bash)"
            micromamba activate "$ENV_NAME"
        fi

        {workflow.basedir}/index-bioentities/bin/index_organism_annotations.sh
        """
