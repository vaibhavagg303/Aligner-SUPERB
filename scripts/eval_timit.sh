#!/bin/bash

stage=-1

. scripts/parse_options.sh || exit 1

# Ensure conda commands work within the script
eval "$(conda shell.bash hook)"

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

if [ $stage -le 0 ]; then
    log "Stage 0: Download & Prepare TIMIT"
    # Using the nemo environment as it has lhotse installed
    conda activate nemo
    lhotse download timit datasets
    lhotse prepare timit datasets/timit manifests/timit

    for sub in DEV TEST TRAIN; do
        lhotse cut simple --recording-manifest manifests/timit/timit_recordings_${sub}.jsonl.gz \
            --supervision-manifest manifests/timit/timit_supervisions_${sub}.jsonl.gz \
            manifests/timit/timit_cuts_${sub}.jsonl.gz
    done
    conda deactivate
fi

if [ $stage -le 1 ]; then
    log "Stage 1: Prepare Target TextGrid files"
    conda activate nemo
    mkdir -p alignments/TIMIT_TARGET_DEV
    python scripts/covert_lhotse_to_tgt.py `pwd` alignments/TIMIT_TARGET_DEV
    conda deactivate
fi

if [ $stage -le 2 ]; then
    log "Stage 2: Prepare NFA json files"
    conda activate nemo
    python -c"
import os
import sys
from pathlib import Path
from nemo.collections.asr.parts.utils.manifest_utils import write_manifest
from lhotse import load_manifest

def get_source_file(cut):
    assert len(cut.recording.sources) == 1
    source = cut.recording.sources[0].source
    return source


def get_supervision_text(supervision):
    return ' '.join([w[0] for w in supervision.alignment['word']])


DIR, LINKDIR = sys.argv[1], sys.argv[2]

# for sub in ['DEV', 'TEST', 'TRAIN']:
for sub in ['DEV']:
    cuts = load_manifest(f'manifests/timit/timit_cuts_{sub}.jsonl.gz')

    meta = []
    for cut in cuts:
        # text = '|'.join([s.text for s in cut.supervisions])
        text = '|'.join([get_supervision_text(s) for s in cut.supervisions])

        audio_filepath = f'{LINKDIR}/{sub}_{cut.id}.wav'
        assert Path(audio_filepath).exists(), f'File {audio_filepath} does not exist'
        meta.append({'audio_filepath': audio_filepath, 'text': text})

    write_manifest(f'manifests/timit/NFA_{sub}_manifest_with_text.json', meta)
" `pwd` `pwd`/alignments/TIMIT_TARGET_DEV
    conda deactivate
fi

if [ $stage -le 3 ]; then
    log "Stage 3: Generate MFA TextGrid files"

    # Using the MFA environment
    conda activate mfa || exit 1

    # https://montreal-forced-aligner.readthedocs.io/en/latest/first_steps/example.html#alignment-example
    export MFA_ROOT_DIR=~/Documents/MFA
    mfa model download acoustic english_us_arpa
    mfa model download dictionary english_us_arpa

    # for sub in DEV TEST TRAIN;do
    for sub in DEV; do
        # --single_speaker skip fMLLR for speaker adaptation
        mfa align --single_speaker --clean alignments/TIMIT_TARGET_${sub} english_us_arpa english_us_arpa alignments/TIMIT_MFA_${sub} || exit 1
    done
    # cp alignments/TIMIT_TARGET_${sub}/*.wav alignments/TIMIT_MFA_${sub}
    conda deactivate
fi

if [ $stage -le 4 ]; then
    log "Stage 4: Generate NFA TextGrid files"

    conda activate nemo
    NFA_DIR=third_party/NeMo
    # for sub in DEV TEST TRAIN;do
    for sub in DEV; do
        python ${NFA_DIR}/tools/nemo_forced_aligner/align.py \
            additional_segment_grouping_separator="|" \
            "save_output_file_formats=['tgt']" \
            pretrained_name="stt_en_fastconformer_hybrid_large_pc" \
            manifest_filepath=manifests/timit/NFA_${sub}_manifest_with_text.json \
            output_dir=alignments/TIMIT_NFA_${sub}
    done
    conda deactivate
fi

if [ $stage -le 5 ]; then
    log "Stage 5: Generate ctc-forced-aligner TextGrid files"

    conda activate ctc-aligner
    # for sub in DEV TEST TRAIN;do
    for sub in DEV; do
        python scripts/ctc_forced_aligner_cli.py --language "eng" \
            --manifest_filepath manifests/timit/NFA_${sub}_manifest_with_text.json \
            --output_dir alignments/TIMIT_CtcFA_${sub}
    done
    conda deactivate
fi

if [ $stage -le 6 ]; then
    log "Stage 6: Generate whisperx TextGrid files"

    conda activate whisperx
    # for sub in DEV TEST TRAIN;do
    for sub in DEV; do
        python scripts/whisperx_aligner_cli.py --language "en" \
            --manifest_filepath manifests/timit/NFA_${sub}_manifest_with_text.json \
            --output_dir alignments/TIMIT_WhisperxCtcFA_${sub}
    done
    conda deactivate
fi

if [ $stage -le 7 ]; then
    log "Stage 7: Generate lhotse TextGrid files"

    conda activate whisperx
    # for sub in DEV TEST TRAIN;do
    for sub in DEV; do
        python scripts/lhotse_aligner_cli.py --language "en" \
            --manifest_filepath manifests/timit/NFA_${sub}_manifest_with_text.json \
            --aligner "MMSForcedAligner" \
            --output_dir alignments/TIMIT_LhotseMMSForcedAligner_${sub}

        python scripts/lhotse_aligner_cli.py --language "en" \
            --manifest_filepath manifests/timit/NFA_${sub}_manifest_with_text.json \
            --aligner "ASRForcedAligner" \
            --output_dir alignments/TIMIT_LhotseASRForcedAligner_${sub}
    done
    conda deactivate
fi

if [ $stage -le 8 ]; then
    log "Stage 8: Evaluate alignments"

    # Check if target directories exist
    if [ ! -d "alignments/TIMIT_TARGET_DEV" ]; then
        log "Target TextGrid not found. Please run stage 2 first"
        exit 1
    fi

    if [ ! -d "alignments/TIMIT_MFA_DEV" ]; then
        log "MFA alignment not found. Please run stage 3 first"
        exit 1
    fi

    if [ ! -d "alignments/TIMIT_NFA_DEV" ]; then
        log "NFA alignment not found. Please run stage 4 first"
        exit 1
    fi
    
    # Using the appropriate environment for evaluation
    # Assuming alignersuperb is installed in the nemo environment
    conda activate whisperx
    alignersuperb metrics -t alignments/TIMIT_TARGET_DEV alignments/TIMIT_MFA_DEV
    alignersuperb metrics -t alignments/TIMIT_TARGET_DEV alignments/TIMIT_NFA_DEV
    alignersuperb metrics -t alignments/TIMIT_TARGET_DEV alignments/TIMIT_CtcFA_DEV
    alignersuperb metrics -t alignments/TIMIT_TARGET_DEV alignments/TIMIT_WhisperxCtcFA_DEV
    alignersuperb metrics -t alignments/TIMIT_TARGET_DEV alignments/TIMIT_LhotseASRForcedAligner_DEV
    alignersuperb metrics -t alignments/TIMIT_TARGET_DEV alignments/TIMIT_LhotseMMSForcedAligner_DEV
    conda deactivate
fi
