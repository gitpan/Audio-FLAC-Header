/* $Id: Header.xs,v 1.1 2004/09/29 07:18:44 daniel Exp $ */

/* This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 *
 * Chunks of this code have been borrowed and influenced from the FLAC source.
 *
 */

#ifdef __cplusplus
"C" {
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef __cplusplus
}
#endif

#include <FLAC/all.h>

/* strlen the length automatically */
#define my_hv_store(a,b,c)   hv_store(a,b,strlen(b),c,0)
#define my_hv_fetch(a,b)     hv_fetch(a,b,strlen(b),0)

void _cuesheet_frame_to_msf(unsigned frame, unsigned *minutes, unsigned *seconds, unsigned *frames) {       

	*frames = frame % 75;
	frame /= 75;
	*seconds = frame % 60;
	frame /= 60;
	*minutes = frame;
}

void _read_metadata(HV *self, char *path, FLAC__StreamMetadata *block, unsigned block_number) {

	unsigned i, j;

	switch (block->type) {

		case FLAC__METADATA_TYPE_STREAMINFO:
		{
			HV *info = newHV();
			float totalSeconds;

			my_hv_store(info, "MINIMUMBLOCKSIZE", newSVuv(block->data.stream_info.min_blocksize));
			my_hv_store(info, "MAXIMUMBLOCKSIZE", newSVuv(block->data.stream_info.max_blocksize));

			my_hv_store(info, "MINIMUMFRAMESIZE", newSVuv(block->data.stream_info.min_framesize));
			my_hv_store(info, "MAXIMUMFRAMESIZE", newSVuv(block->data.stream_info.max_framesize));

			my_hv_store(info, "SAMPLERATE", newSVuv(block->data.stream_info.sample_rate));
			my_hv_store(info, "NUMCHANNELS", newSVuv(block->data.stream_info.channels));
			my_hv_store(info, "BITSPERSAMPLE", newSVuv(block->data.stream_info.bits_per_sample));
			my_hv_store(info, "TOTALSAMPLES", newSVnv(block->data.stream_info.total_samples));

			if (block->data.stream_info.md5sum[0]) {

				/* Initialize an SV with the first element,
				   and then append to it. If we don't do it this way, we get a "use of
				   uninitialized element" in subroutine warning. */
				SV *md5 = newSVpvf("%02x", (unsigned)block->data.stream_info.md5sum[0], 32);

				for (i = 1; i < 16; i++) {
					sv_catpvf(md5, "%02x", (unsigned)block->data.stream_info.md5sum[i]);
				}

				my_hv_store(info, "MD5CHECKSUM", md5);
			}

			my_hv_store(self, "info", newRV_noinc((SV*) info));

			/* Store some other metadata for backwards compatability with the original Audio::FLAC */
			/* needs to be higher resolution */
			totalSeconds = block->data.stream_info.total_samples / (float)block->data.stream_info.sample_rate;

			if (totalSeconds <= 0) {
				warn("totalSeconds is 0 - we couldn't find either TOTALSAMPLES or SAMPLERATE!\n",
					"setting totalSeconds to 1 to avoid divide by zero error!\n"
				);

				totalSeconds = 1;
			}

			my_hv_store(self, "trackTotalLengthSeconds", newSVnv(totalSeconds));

			my_hv_store(self, "trackLengthMinutes", newSVnv((int)totalSeconds / 60));
			my_hv_store(self, "trackLengthSeconds", newSVnv((int)totalSeconds % 60));
			my_hv_store(self, "trackLengthFrames", newSVnv((totalSeconds - (int)totalSeconds) * 75));

			break;
		}

		case FLAC__METADATA_TYPE_PADDING:
		case FLAC__METADATA_TYPE_SEEKTABLE:
			/* Don't handle these yet. */
			break;

		case FLAC__METADATA_TYPE_APPLICATION:
		{
			/* Initialize an empty SV, and then append to it */
			SV *appId = newSVpv("", 8);
			HV *app   = newHV();

			if (block->data.application.id[0]) {

				for (i = 0; i < 4; i++) {
					sv_catpvf(appId, "%02x", block->data.application.id[i]);
				}
			}

			if (block->data.application.data != 0) {
				my_hv_store(app, (char*)appId, newSVpv(block->data.application.data, 0));
			}
			
			my_hv_store(self, "application",  newRV_noinc((SV*) app));

			break;
		}

		case FLAC__METADATA_TYPE_VORBIS_COMMENT:
		{
			/* store the pointer location of the '=', poor man's split() */
			char *half;
			AV   *rawTagArray = newAV();;
			HV   *tags = newHV();

			my_hv_store(tags, "VENDOR", newSVpv(block->data.vorbis_comment.vendor_string.entry, 0));

			for (i = 0; i < block->data.vorbis_comment.num_comments; i++) {

				char *entry = SvPV_nolen(newSVpv(
					block->data.vorbis_comment.comments[i].entry,
					block->data.vorbis_comment.comments[i].length
				));

				/* store the raw tag, before we uppercase it */
				av_push(rawTagArray, newSVpv(entry, 0));

				half = strchr(entry, '=');

				if (half == NULL) {
					warn("Comment \"%s\" missing \'=\', skipping...\n", entry);
					continue;
				}

				/* make the key be uppercased */
				for (j = 0; j <= half - entry; j++) {
					entry[j] = toUPPER(entry[j]);
				}

				hv_store(tags, entry, half - entry, newSVpv(half + 1, 0), 0);
			}

			my_hv_store(self, "tags", newRV_noinc((SV*) tags));
			my_hv_store(self, "rawTags", newRV_noinc((SV*) rawTagArray));

			break;
		}

		case FLAC__METADATA_TYPE_CUESHEET:
		{
			AV *cueArray = newAV();;

			/* A lot of this comes from flac/src/share/grabbag/cuesheet.c */
			const FLAC__StreamMetadata_CueSheet *cs;
			unsigned track_num, index_num;

			cs = &block->data.cue_sheet;

			if (*(cs->media_catalog_number)) {
				av_push(cueArray, newSVpvf("CATALOG %s\n", cs->media_catalog_number));
			}

			av_push(cueArray, newSVpvf("FILE \"%s\" FLAC\n", path));

			for (track_num = 0; track_num < cs->num_tracks-1; track_num++) {

				const FLAC__StreamMetadata_CueSheet_Track *track = cs->tracks + track_num;

				av_push(cueArray, newSVpvf("  TRACK %02u %s\n", 
					(unsigned)track->number, track->type == 0? "AUDIO" : "DATA"
				));

				if (track->pre_emphasis) {
					av_push(cueArray, newSVpv("    FLAGS PRE\n", 0));
				}

				if (*(track->isrc)) {
					av_push(cueArray, newSVpvf("    ISRC %s\n", track->isrc));
				}

				for (index_num = 0; index_num < track->num_indices; index_num++) {

					const FLAC__StreamMetadata_CueSheet_Index *index = track->indices + index_num;

					SV *indexSV = newSVpvf("    INDEX %02u ", (unsigned)index->number);

					if (cs->is_cd) {

						unsigned logical_frame = (unsigned)((track->offset + index->offset) / (44100 / 75));
						unsigned m, s, f;

						_cuesheet_frame_to_msf(logical_frame, &m, &s, &f);

						sv_catpvf(indexSV, "%02u:%02u:%02u\n", m, s, f);

					} else {
#ifdef _MSC_VER
						sv_catpvf(indexSV, "%I64u\n", track->offset + index->offset);
#else
						sv_catpvf(indexSV, "%llu\n", track->offset + index->offset);
#endif
					}


					av_push(cueArray, indexSV);
				}
			}

#ifdef _MSC_VER
			av_push(cueArray, newSVpvf("REM FLAC__lead-in %I64u\n", cs->lead_in));
			av_push(cueArray, newSVpvf("REM FLAC__lead-out %u %I64u\n", (unsigned)cs->tracks[track_num].number, cs->tracks[track_num].offset));
#else
			av_push(cueArray, newSVpvf("REM FLAC__lead-in %llu\n", cs->lead_in));
			av_push(cueArray, newSVpvf("REM FLAC__lead-out %u %llu\n", (unsigned)cs->tracks[track_num].number, cs->tracks[track_num].offset));
#endif

			my_hv_store(self, "cuesheet",  newRV_noinc((SV*) cueArray));

			break;
		}

		/* XXX- Just ignore for now */
		default:
			break;
	}
}

/* From src/metaflac/operations.c */
void print_error_with_chain_status(FLAC__Metadata_Chain *chain, const char *format, ...) {

	const FLAC__Metadata_ChainStatus status = FLAC__metadata_chain_status(chain);
	va_list args;

	FLAC__ASSERT(0 != format);

	va_start(args, format);
	(void) vfprintf(stderr, format, args);
	va_end(args);

	warn("status = \"%s\"\n", FLAC__Metadata_ChainStatusString[status]);

	if (status == FLAC__METADATA_CHAIN_STATUS_ERROR_OPENING_FILE) {

		warn("The FLAC file could not be opened. Most likely the file does not exist or is not readable.");

	} else if (status == FLAC__METADATA_CHAIN_STATUS_NOT_A_FLAC_FILE) {

		warn("The file does not appear to be a FLAC file.");

	} else if (status == FLAC__METADATA_CHAIN_STATUS_NOT_WRITABLE) {

		warn("The FLAC file does not have write permissions.");

	} else if (status == FLAC__METADATA_CHAIN_STATUS_BAD_METADATA) {

		warn("The metadata to be writted does not conform to the FLAC metadata specifications.");

	} else if (status == FLAC__METADATA_CHAIN_STATUS_READ_ERROR) {

		warn("There was an error while reading the FLAC file.");

	} else if (status == FLAC__METADATA_CHAIN_STATUS_WRITE_ERROR) {

		warn("There was an error while writing FLAC file; most probably the disk is full.");

	} else if (status == FLAC__METADATA_CHAIN_STATUS_UNLINK_ERROR) {

		warn("There was an error removing the temporary FLAC file.");
	}
}

MODULE = Audio::FLAC::Header PACKAGE = Audio::FLAC::Header

SV*
new_XS(class, path)
	char *class;
	char *path;

	CODE:

	HV *self = newHV();
	SV *obj_ref = newRV_noinc((SV*) self);

	/* Start to walk the metadata list */
	FLAC__Metadata_Chain *chain = FLAC__metadata_chain_new();

        if (chain == 0) {
                die("Out of memory allocating chain");
		XSRETURN_UNDEF;
	}

        if (!FLAC__metadata_chain_read(chain, path)) {
                print_error_with_chain_status(chain, "%s: ERROR: reading metadata", path);
		XSRETURN_UNDEF;
        }

	{

		FLAC__Metadata_Iterator *iterator = FLAC__metadata_iterator_new();
		FLAC__StreamMetadata *block;
		FLAC__bool ok = true;
		unsigned block_number = 0;

		if (iterator == 0) {
			die("out of memory allocating iterator");
		}

        	FLAC__metadata_iterator_init(iterator, chain);

        	do {
               		block = FLAC__metadata_iterator_get_block(iterator);
                	ok &= (0 != block);

			if (!ok) {

				warn("%s: ERROR: couldn't get block from chain", path);

			} else {

                        	_read_metadata(self, path, block, block_number);
			}

                	block_number++;

        	} while (ok && FLAC__metadata_iterator_next(iterator));

		FLAC__metadata_iterator_delete(iterator);
	}

	FLAC__metadata_chain_delete(chain);

	/* Find the offset of the start pos for audio blocks (ie: after metadata) */
	{
		unsigned int  is_last = 0;
		unsigned char buf[4];
		long len;
		struct stat st;
		float totalSeconds;
		PerlIO *FH;

		if ((FH = PerlIO_open(path, "r")) == NULL) {
			warn("Couldn't open file [%s] for reading!\n", path);
			XSRETURN_UNDEF;
		}

		if (PerlIO_read(FH, &buf, 4) == -1) {
			warn("Couldn't read magic fLaC header!\n");
			XSRETURN_UNDEF;
		}

		if (memcmp(buf, "fLaC", 4)) {
			warn("Couldn't read magic fLaC header - got gibberish instead!\n");
			XSRETURN_UNDEF;
		}
			
		while (!is_last) {

			if (PerlIO_read(FH, &buf, 4) != 4) {
				warn("Couldn't read 4 bytes of the metadata block!\n");
				XSRETURN_UNDEF;
			}

			is_last = (unsigned int)(buf[0] & 0x80);

			len = (long)((buf[1] << 16) | (buf[2] << 8) | (buf[3]));

			PerlIO_seek(FH, len, SEEK_CUR);
		}

		len = PerlIO_tell(FH);
		PerlIO_close(FH);

		my_hv_store(self, "startAudioData", newSVnv(len));

		/* Now calculate the bit rate and file size */
		totalSeconds = (float)SvIV(*(my_hv_fetch(self, "trackTotalLengthSeconds")));

		/* Find the file size */
		if (stat(path, &st) == 0) {
			my_hv_store(self, "fileSize", newSViv(st.st_size));
		} else {
			warn("Couldn't stat file: [%s], might be more problems ahead!", path);
		}

		my_hv_store(self, "bitRate", newSVnv(8.0 * (st.st_size - len) / totalSeconds));
	}

	/* Bless the hashref to create a class object */
	sv_bless(obj_ref, gv_stashpv(class, FALSE));

	RETVAL = obj_ref;

	OUTPUT:
	RETVAL
