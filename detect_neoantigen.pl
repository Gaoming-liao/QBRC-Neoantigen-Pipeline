###########  detect neoantigen from somatic mutations  ##################
#
# prerequisite in path: 
# gzip, Rscript, iedb (MHC_I, MHC_II), featureCounts (>=1.6), novoalign, samtools (>=1.4), STAR (>=2.7.2, if providing RNA-Seq fastq files)
# Athlates (need lib64 of gcc>=5.4.0 in LD_LIBRARY_PATH, cp files under data/msa_for_athlates to Athlates_2014_04_26/db/msa and data/ref.nix to Athlates_2014_04_26/db/ref), 
# annovar (>=2019Oct24, humandb in default position), python (python 2)
# mixcr (>=3.0.3), perl (version 5, Parallel::ForkManager installed)
#
# attention: 
# need to make sure the gene annotation of mutation data and expression data are the same
# if inputing bam files, the bam files are assumed to be paired-ended
#
# input format:
# somatic: somatic mutaion calling file of exome-seq data, generated by somatic.pl, or can be another file that follows the output format of somatic.pl
# expression_somatic: somatic mutation calling file of the corresponding RNA-Seq data, the format is the same as $somatic
#                     if this data are not available, use "NA" instead
# max_normal_cutoff: maximum VAF in normal sample
# min_tumor_cutoff: minimum VAF in tumor sample
# build: human genome build, hg19 or hg38
# output: output folder, safer to make "output" a folder that only holds results of this analysis job
# fastq1,fastq2: fastq files (must be gzipped) of tumor exome-seq for HLA type. Alternatively
#               (1) if you do not have raw fastq files but have the paired-end exome-seq bam files, use "bam path_to_bam1,path_to_bam2,path_to_bam3".
#               You can give one or multiple bam files. But using bam files is not preferred. Speed is slow when individual bam file is >10GB.
#               (2) if want to use pre-existing HLA typing results, use "pre-existing path-to-file" in place of the fastq files,
#               the typing file (path-to-file) can contain one or more lines. Each line is for one HLA class (A, B, C, DQB1, DRB1)
#               Any class can appear 0 or 1 time in the typing file, but no more than 1 time.
#               Each line (class) follows this format: "class\ttype1\ttype2\t0". An example: example/typing.txt
# exp_bam: expression data
#          (1) If expression data do not exist at all, use "NA" instead, and accordingly, $gtf and $rpkm_cutoff will not matter anymore
#          (2) In this case, mixcr will be run on exome-seq data
#          (3) If raw RNA-Seq fastq files (single-end or paired-end, gzip-ed) are available, 
#              use "path-to-STAR-index:path-to-fastq1.gz,path-top-fastq2.gz" or "path-to-STAR-index:path-to-fastq.gz".
#          (4) If bam files are available (paired-end),
#              use "path-to-STAR-index:bam,bam_file_path".
#          (5) If transcript level and exon level gene expression data are available, 
#              compile them into the formats of these two files: example/exon.featureCounts, example/transcript.featureCounts,
#              and specify these two files in the exp_bam input parameter as "counts:path-to-exon-count,path-to-transcript-count"
#              $gtf will not matter anymore
# gtf: gtf file for featureCounts
# mhc_i, mhc_ii: folders to the iedb mhc1 and mhc2 binding prediction algorithms, http://www.iedb.org/
# percentile_cutoff: percentile cutoff for binding affinity (0-100), recommended: 2
# rpkm_cutoff: RPKM cutoff for filtering expressed transcripts and exons, recommended: 1
# thread: number of threads to use, recommended: 32
# max_mutations: if more than this number of mutations are left after all filtering, the program will abort. 
#   Otherwise, it will take too much time. recommended: 50000
#
#!/usr/bin/perl
use strict;
use warnings;
use Cwd 'abs_path';

my ($somatic,$expression_somatic,$max_normal_cutoff,$min_tumor_cutoff,$build,$output,$fastq1,$fastq2,$exp_bam,$gtf,
  $mhc_i,$mhc_ii,$percentile_cutoff,$rpkm_cutoff,$thread,$max_mutations)=@ARGV;
my ($path);

# prepare
$path=abs_path($0);
$path=~s/detect_neoantigen\.pl//;
$path.="/script/";

unless (-d $output) {mkdir($output) or die "Error: cannot create directory ".$output."!\n";}
if (!-w $output) {die "Error: directory ".$output." is not writable!\n";}
system_call("rm -f ".$output."/*error*");
if (!-e $somatic) {die "Error: somatic mutation callling file does not exist!\n";}
system_call("cp ".$somatic." ".$output."/neoantigen");
system_call("cp ".$somatic." ".$output."/somatic_mutation_tumor.txt");
$somatic=$output."/neoantigen";

# expression analysis
if ($exp_bam ne "NA")
{
  if ($exp_bam=~/counts:(.*),(.*)/) # copy existing expression counting files, consistent with featureCounts format
  {
    system_call("cp ".$1." ".$output."/exon.featureCounts");
    system_call("cp ".$2." ".$output."/transcript.featureCounts");
  }else # call featureCounts
  {
    system_call("perl ".$path."/expression.pl ".$exp_bam." ".$gtf." ".$output." ".$thread);
  }
}else
{
  # disable rpkm cutoff
  $rpkm_cutoff=-1;

  if ($fastq1 ne "pre-existing" && $fastq1 ne "bam") # tumor RNA-Seq data are not provided, keep all putative neoantigens
  {
    # run mixcr on exome-seq fastqs
    system("mixcr align -s hs -f -t ".$thread." -OvParameters.geneFeatureToAlign=VGeneWithP ".
      "-OallowPartialAlignments=true ".$fastq1." ".$fastq2." ".$output."/alignments.vdjca > ".$output."/mixcr1.txt");
    system("mixcr assemblePartial -f ".$output."/alignments.vdjca ".$output.
      "/alignment_contigs.vdjca > ".$output."/mixcr21.txt");
    system("mixcr assemblePartial -f ".$output."/alignment_contigs.vdjca ".$output.
      "/alignment_contigs2.vdjca > ".$output."/mixcr22.txt");
    system("mixcr extend -f ".$output."/alignment_contigs2.vdjca ".$output.
      "/alignmentsRescued_2_extended.vdjca > ".$output."/mixcr3.txt");
    system("mixcr assemble -ObadQualityThreshold=15 -OaddReadsCountOnClustering=true -f -t ".$thread." ".
      $output."/alignmentsRescued_2_extended.vdjca ".$output."/clones.clns > ".$output."/mixcr4.txt");
    system("mixcr exportClones -f ".$output."/clones.clns ".$output."/clones.txt > ".$output."/mixcr5.txt");

    system("rm -f ".$output."/alignment*");
    system("rm -f ".$output."/clones.clns");
    system("rm -f ".$output."/mixcr*.txt");
  }
}

# predict putative neoantigen from somatic mutations
system_call("perl ".$path."/predict_neoantigen.pl ".$somatic." ".$max_normal_cutoff." ".$min_tumor_cutoff." ".$build." ".$rpkm_cutoff." ".$max_mutations);
unlink($somatic);
if (! -e $somatic."_filtered") {exit 1;}

# predict HLA subtype
if ($fastq1 eq "bam") # given bam files 
{
  system_call("perl ".$path."/bam2fastq.pl ".$fastq2." ".$output." ".$thread);
  if (! -e $output."/fastq1.fastq")
  {
    print "Error: Fastq file doesn't exist!\n";
    exit;
  }
  system_call("perl ".$path."/hla.pl ".$output."/fastq1.fastq ".$output."/fastq2.fastq ".$output." ".$path." ".$thread);
}elsif ($fastq1 ne "pre-existing") # given fastq files 
{
  system_call("cp ".$fastq1." ".$output."/fastq1.fastq.gz");
  system_call("gzip -d -f ".$output."/fastq1.fastq.gz");

  system_call("cp ".$fastq2." ".$output."/fastq2.fastq.gz");
  system_call("gzip -d -f ".$output."/fastq2.fastq.gz");
  
  system_call("perl ".$path."/hla.pl ".$output."/fastq1.fastq ".$output."/fastq2.fastq ".$output." ".$path." ".$thread);
}else # given existing typing file
{
  system_call("cp ".$fastq2." ".$output."/typing.txt");
}
unlink($output."/fastq1.fastq");
unlink($output."/fastq2.fastq");
if (! -e $output."/typing.txt") {exit 1;}

# predict affinity
system_call("perl ".$path."/affinity.pl ".$mhc_i." ".$mhc_ii." ".$somatic." ".$output."/typing.txt ".$percentile_cutoff);
system_call("Rscript ".$path."/expressed_neoantigen.R ".$rpkm_cutoff." ".$somatic." ".$output." ".$path." ".$expression_somatic);
unlink($somatic."_filtered");

# CSiN
system_call("Rscript ".$path."/CSiN.R ".$output);
system_call("rm -f -r ".$output."/_STARtmp");

sub system_call
{
  my $command=$_[0];
  print "\n".$command."\n";
  system($command);
}

#perl /home2/twang6/software/immune/neoantigen/detect_neoantigen.pl \
#/project/bioinformatics/Xiao_lab/shared/neoantigen/data/tmp/somatic_mutations_hg38.txt \
#NA 0.02 0.05 hg38 \
#/project/bioinformatics/Xiao_lab/shared/neoantigen/data/tmp1 \
#/project/BICF/shared/Kidney/Projects/Pancreatic_Mets/RAW/DNA/1620A-MK-312_S0_L001_R1_001.fastq.gz \
#/project/BICF/shared/Kidney/Projects/Pancreatic_Mets/RAW/DNA/1620A-MK-312_S0_L001_R2_001.fastq.gz \
#/project/shared/xiao_wang/data/hg38/STAR:bam,\
#/project/bioinformatics/Xiao_lab/shared/genomics/Sato/RNA_Seq/_EGAR00001121538_ccRCC-51-tumor_RNAseq.bam \
#/home2/twang6/data/genomes/hg38/hg38_genes.gtf \
#/project/bioinformatics/Xiao_lab/shared/neoantigen/code/mhc_i \
#/project/bioinformatics/Xiao_lab/shared/neoantigen/code/mhc_ii \
#2 1 32 50000

