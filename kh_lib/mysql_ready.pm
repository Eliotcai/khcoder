package mysql_ready;
use strict;

use Jcode;
use Benchmark;

use kh_project;
use kh_jchar;
use kh_dictio;
use kh_mailif;
use mysql_exec;
use mysql_ready::check;
use mysql_ready::doclength;
use mysql_ready::heap;
use mysql_ready::df;

my $rows_per_once = 30000;    # MySQLからPerlに一度に読み込む行数
my $data_per_1ins = 200;      # 一度にINSERTする値の数

sub first{
	my $class = shift;
	my $self;
	$self->{temp} = 'temp';
	bless $self, $class;

	$::config_obj->in_preprocessing(1);
	if ($::config_obj->use_heap) {
		$self->{type_heap} = ' TYPE=HEAP ';
	} else {
		$self->{type_heap} = '';
	}

		my $ta0 = new Benchmark;
	kh_morpho->run;
		my $ta1 = new Benchmark;
		print "Morpho1\t",timestr(timediff($ta1,$ta0)),"\n";
	if ($::config_obj->os eq 'win32'){
		kh_jchar->to_euc($::project_obj->file_MorphoOut);
			my $ta2 = new Benchmark;
			print "Morpho2\t",timestr(timediff($ta2,$ta1)),"\n";
	}
		my $t0 = new Benchmark;
	$self->readin;                 # rowdata, outvar, outvar_lab
		my $t1 = new Benchmark;
		print "Read\t",timestr(timediff($t1,$t0)),"\n";
	$self->reform;                 # hinshi, genkei, katuyo, hyoso, khhinshi
	$self->tag_fix;                # hyoso, genkei
		my $t15 = new Benchmark;
		print "Format\t",timestr(timediff($t15,$t1)),"\n";
	kh_dictio->readin->save;
	$self->hyosobun;
		my $t2 = new Benchmark;
		print "Strat1\t",timestr(timediff($t2,$t15)),"\n";
	$self->rowtxt;
		my $t3 = new Benchmark;
		print "RawTXT\t",timestr(timediff($t3,$t2)),"\n";
	$self->tanis;
		my $t4 = new Benchmark;
		print "Strat2\t",timestr(timediff($t4,$t3)),"\n";
	mysql_ready::df->calc;
		my $t5 = new Benchmark;
		print "df\t",timestr(timediff($t5,$t4)),"\n";
	mysql_ready::check->do;
		my $t6 = new Benchmark;
		print "Check\t",timestr(timediff($t6,$t5)),"\n";

	# データベース内の一時テーブルをクリア
	mysql_exec->clear_tmp_tables;
	mysql_ready::heap->clear_heap;
	mysql_exec->drop_table("hyosobun_t");
	mysql_exec->drop_table("hghi");
	
	kh_mailif->success;
	$::config_obj->in_preprocessing(0);
}


#----------------------#
#   データの読み込み   #

sub readin{
	my $self = shift;


	# ローデータの読み込み
	mysql_exec->drop_table("rowdata");
	mysql_exec->do("create table rowdata
		(
			hyoso varchar(255) not null,
			yomi varchar(255) not null,
			genkei varchar(255) not null,
			hinshi varchar(255) not null,
			katuyogata varchar(255) not null,
			katuyo varchar(255) not null,
			id int auto_increment primary key not null
		)
	",1);

	my $thefile = "'".$::project_obj->file_MorphoOut."'";
	$thefile =~ tr/\\/\//;
	mysql_exec->do("LOAD DATA LOCAL INFILE $thefile INTO TABLE rowdata",1);

	# フィールド長の取得
	my $t = mysql_exec->select("
		SELECT
			MAX( LENGTH(hyoso) ) AS hyoso,
			MAX( LENGTH(genkei) ) AS genkei,
			MAX( LENGTH(hinshi) ) AS hinshi,
			MAX( LENGTH(katuyo) ) AS katuyo
		FROM rowdata
	",1)->hundle;
	my $r = $t->fetchrow_hashref;
	$t->finish;
	my $total_length;
	my $sql_temp;
	foreach my $key (keys %{$r}){
		my $len = $r->{$key} + 4;
		$self->length($key,$len);
	}

	mysql_ready::heap->rowdata($self);

	# 外部変数用のテーブルを準備
	unless ( mysql_exec->table_exists('outvar') ){
		mysql_exec->do("create table outvar
			(
				name varchar(255) not null,
				tab varchar(255) not null,
				col varchar(255) not null,
				tani varchar(10) not null,
				id int auto_increment primary key not null
			)
		",1);
	}
	unless ( mysql_exec->table_exists('outvar_lab') ){
		mysql_exec->do("create table outvar_lab
			(
				var_id int not null,
				val varchar(255) not null,
				lab varchar(255) not null,
				id int auto_increment primary key not null
			)
		",1);
	}
}

#----------------#
#   データ整形   #

sub reform{
	my $self = shift;


	# キャッシュ・テーブル作成
	mysql_exec->drop_table("hgh");
	my @len = (
		$self->length('hyoso'),
		$self->length('genkei'),
		$self->length('hinshi'),
		$self->length('katuyo')
	);
	mysql_exec->do("
		create table hgh (
			id int auto_increment primary key not null,
			num int not null,
			hyoso varchar($len[0]) not null,
			genkei varchar($len[1]) not null,
			hinshi varchar($len[2]) not null,
			katuyo varchar($len[3]) not null
		)
	", 1);
	mysql_exec->do("
		INSERT
		INTO hgh ( num, hyoso, genkei, hinshi, katuyo)
		SELECT COUNT(*), hyoso, genkei, hinshi, katuyo
			FROM rowdata
#			WHERE LENGTH(rowdata.genkei) > 1
			GROUP BY rowdata.hyoso, rowdata.genkei, rowdata.hinshi
	", 1);


	# 品詞テーブル作成
	my $len = $self->length('hinshi');
	mysql_exec->drop_table("hinshi");
	mysql_exec->do("
		create table hinshi (
			id int auto_increment primary key not null,
			name varchar($len) not null
		)
	",1);
		
	mysql_exec->do('
		INSERT
		INTO hinshi (name)
		SELECT (hinshi)
			FROM hgh
			WHERE length(genkei) > 1
			GROUP BY hinshi
	',1);
	mysql_exec->do("alter table hinshi add index index1 (name)",1);


	# 原形テーブル作成
	$len = $self->length('genkei');                         # テーブル準備
	mysql_exec->drop_table("genkei");
	mysql_exec->do("
		create table genkei (
			id int auto_increment primary key not null,
			name varchar($len) not null,
			num int not null,
			hinshi_id int not null,
			khhinshi_id int not null,
			nouse int not null default 0
		)
	",1);

	my $dbhh = DBI->connect("DBI:CSV:f_dir=./config");      # 分類規則準備
	my $th = $dbhh->prepare("
		SELECT kh_hinshi,condition1,condition2,hinshi_id
		FROM hinshi_chasen
	") or die;
	$th->execute or die;
	my $rule = $th->fetchall_arrayref;

                                                            # データ準備
	mysql_exec->drop_table("hgh2");
	mysql_exec->do("
		create table hgh2 (
			id INT auto_increment primary key not null,
			genkei varchar($len) not null,
			sum INT,
			h_id INT,
			h_name varchar(".$self->length('hinshi').")
		)
	",1);
	mysql_exec->do("
		INSERT INTO hgh2 (genkei, sum, h_id, h_name)
		SELECT hgh.genkei, SUM(num), hinshi.id, hinshi.name
		FROM hgh, hinshi
		WHERE hgh.hinshi=hinshi.name
		GROUP BY hgh.genkei, hgh.hinshi
	",1);

	my ($num, $con) = (0,'');
	my $id = 1;
	while (1){
		my $td = mysql_exec->select(
			mysql_ready->genkei_sql($id, $id + $rows_per_once),
			1
		)->hundle;
		unless ($td->rows > 0){
			last;
		}
		$id += $rows_per_once;
		
		while (my $d = $td->fetch){                             # 振り分け
			my $kh_hinshi = '9999';
			foreach my $i (@{$rule}){
				if ( index("$d->[3]","$i->[1]") == 0 ){        # 条件1
					if ($i->[2] eq 'ひらがな'){            # 条件2:ひらがな
						if ($d->[0] =~ /^(\xA4[\xA1-\xF3])+$/o){
							$kh_hinshi = $i->[3];
							last;
						}
					}
					elsif ($i->[2] eq '一文字'){           # 条件2:ひらがな
						if (length($d->[0]) == 2){
							$kh_hinshi = $i->[3];
							last;
						}
					}
					elsif ($i->[2] eq 'HTML'){             # 条件2:HTML
						if ( 
							   ($d->[0] =~ /<h[1-5]>/io)
							|| ($d->[0] =~ /<\/h[1-5]>/io) 
						){
							$kh_hinshi = $i->[3];
							last;
						}
					}
					elsif($i->[2] eq '否定'){             # 条件2:HTML
						if (
							($d->[0] eq 'ない')
							|| ($d->[0] eq 'まい')
							|| ($d->[0] eq 'ぬ')
						){
							$kh_hinshi = $i->[3];
							last;
						}
					}
					else {                                 # 条件2無しの場合
						$kh_hinshi = $i->[3];
						last;
					}
				}
			}
			$con .= "('$d->[0]',$d->[1],$d->[2],$kh_hinshi),";
			++$num;
			if ($num == $data_per_1ins){               # DBに投入
				chop $con;
				mysql_exec->do("
					INSERT
					INTO genkei (name, num, hinshi_id, khhinshi_id)
					VALUES $con
				",1);
				$con = '';
				$num = 0;
			}
		}
		$td->finish;
	}
	
	if ($con){                                         # 残りをDBに投入
		chop $con;
		mysql_exec->do("
			INSERT
			INTO genkei (name, num, hinshi_id, khhinshi_id)
			VALUES $con
		",1);
	}
	mysql_exec->do('alter table genkei add index index1(name,hinshi_id,khhinshi_id)',1);
	mysql_exec->do('alter table genkei add index index2(khhinshi_id)',1);
	mysql_exec->do('alter table genkei add index index3(hinshi_id)',1);


	# KH_品詞テーブルの作成
	mysql_exec->drop_table("khhinshi");
	mysql_exec->do("
		create table khhinshi (
			id int primary key not null,
			name varchar(20) not null
		)
	",1);

	$con = ''; my %temp;
	foreach my $i (@{$rule}){
		unless ($temp{$i->[0]}){
			$con .= "($i->[3],'$i->[0]'),";
			$temp{$i->[0]} = 1;
		}
	}
	$con .= "(9999,'その他')";

	mysql_exec->do("
		INSERT
		INTO khhinshi (id,name)
		VALUES $con
	",1);
	mysql_exec->do('alter table khhinshi add index index1(name,id)',1);


	# キャッシュテーブル(2)作成
	mysql_exec->drop_table("hghi");
	mysql_exec->do("
		create table hghi (
			hyoso varchar($len[0]) not null,
			genkei varchar($len[1]) not null,
			hinshi varchar($len[2]) not null,
			katuyo varchar($len[3]) not null,
			hyoso_id int not null primary key,
			genkei_id int not null,
			hinshi_id int not null,
			num       int not null
		) $self->{type_heap}
	",1);
	mysql_exec->do('
		INSERT
		INTO hghi (hyoso, genkei, hinshi, katuyo, hyoso_id, genkei_id, hinshi_id, num)
		SELECT hgh.hyoso, hgh.genkei, hgh.hinshi, hgh.katuyo, hgh.id, genkei.id, hinshi.id, hgh.num
			FROM hgh, genkei, hinshi
			WHERE
				    hgh.genkei = genkei.name
				AND hgh.hinshi = hinshi.name
				AND genkei.hinshi_id = hinshi.id
	',1); 
	mysql_exec->drop_table("hgh");
	if ($len[0] + $len[1] + $len[2] <= 500){
		mysql_exec->do(
			"alter table hghi add index index1 (hyoso, genkei, hinshi)",
			1
		);
	} else {
		mysql_exec->do("alter table hghi add index index1 (hyoso)",1);
		mysql_exec->do("alter table hghi add index index2 (genkei)",1);
		mysql_exec->do("alter table hghi add index index3 (hinshi)",1);
		mysql_exec->do("alter table hghi add index index4 (katuyo)",1);
	}

	# 活用テーブル作成
	mysql_exec->drop_table("katuyo");
	mysql_exec->do ("
		create table katuyo (
			id int auto_increment primary key not null,
			name varchar($len[3])
		)
	",1);
	mysql_exec->do("
		INSERT INTO katuyo ( name )
		SELECT katuyo FROM hghi
		GROUP BY katuyo
	",1);
	mysql_exec->do("alter table katuyo add index index1 (id, name)",1);


	# 表層テーブル作成
	mysql_exec->drop_table("hyoso");
	mysql_exec->do("
		create table hyoso (
			id int not null primary key,
			name varchar($len[0]) not null,
			len int not null,
			katuyo_id int not null,
			genkei_id int not null,
			num int not null
		)
	",1);
	mysql_exec->do("
		INSERT
		INTO hyoso (id, name, len, genkei_id, num, katuyo_id)
		SELECT hyoso_id, hyoso, LENGTH(hyoso), genkei_id, num, katuyo.id
			FROM hghi, katuyo
			WHERE hghi.katuyo = katuyo.name
	",1);
	mysql_exec->do("alter table hyoso add index index1 (name, genkei_id)",1);
	mysql_exec->do("alter table hyoso add index index2 (genkei_id)",1);
}

sub genkei_sql{
	my $self = shift;
	my $d1 = shift;
	my $d2 = shift;
	
	my $sql = "
		SELECT genkei, sum, h_id, h_name
		FROM hgh2
		WHERE
			    id >= $d1
			AND id  < $d2
	";
	return $sql;
}


#-------------------------#
#   表層-文テーブル作成   #

sub hyosobun{
	my $self = shift;
	
	# 各種準備
	my $t = mysql_exec->select("        # HTMLタグと句読点のhyoso.idを取得
		SELECT hyoso.name, hyoso.id
		FROM hyoso
		WHERE
			   (( name RLIKE '<[Hh][1-5]\>' ) AND ( len = 4 ))
			OR (( name RLIKE '</[Hh][1-5]>' ) AND ( len = 5 ))
			OR ( name = '。' )
	",1)->hundle;
	my $IDs;
	while (my $d = $t->fetch){
		$IDs->{$d->[1]} = $d->[0];
	}
	$t->finish;

	mysql_exec->drop_table("hyosobun");   # テーブル作成
	mysql_exec->do("
		create table hyosobun (
			id int auto_increment primary key not null,
			hyoso_id INT not null,
			h1_id INT not null,
			h2_id INT not null,
			h3_id INT not null,
			h4_id INT not null,
			h5_id INT not null,
			dan_id INT not null,
			bun_id INT not null,
			bun_idt INT not null
		)
	",1);
	mysql_exec->drop_table("hyosobun_t");# 単位用キャッシュ・テーブル作成
	mysql_exec->do("
		create table hyosobun_t (
			h1_id INT not null,
			h2_id INT not null,
			h3_id INT not null,
			h4_id INT not null,
			h5_id INT not null,
			dan_id INT not null,
			bun_id INT not null,
			bun_idt INT not null,
			lc INT not null,
			lw INT not null
		) $self->{type_heap}
	",1);

	# 初期化
	my ($bun, $dan, $h5, $h4, $h3, $h2, $h1, $lastrow, $midashi, $bun2) = 
		(1,1,0,0,0,0,0,0,0,1);
	my ($temp, $c, $maru);
	my ($temp_tani, $last_tani, $c_t, $lw, $lc);
	my $id = 1;
	# 実行
	while (1){
		my $t = mysql_exec->select(
			$self->hyosobun_sql($id, $id + $rows_per_once),
			1
		)->hundle;
		unless ($t->rows > 0){
			last;
		}
		$id += $rows_per_once;


		while (my $d = $t->fetch){
			if ($d->[0] - $lastrow > 1){              # 改行のチェック
				++$dan;
				$bun = 1;
				unless ($maru){
					++$bun2;
				}
			}
			$lastrow = $d->[0];
			if (                                      # HTML開始タグのチェック
				   $IDs->{$d->[1]} eq '<h1>' 
				|| $IDs->{$d->[1]} eq '<H1>'
			){
				++$h1;
				($h2,$h3,$h4,$h5,$dan,$bun,$midashi)
					= (0,0,0,0,0,0,1);
			}
			elsif (
				   $IDs->{$d->[1]} eq '<h2>'
				|| $IDs->{$d->[1]} eq '<H2>'
			){
				++$h2;
				($h3,$h4,$h5,$dan,$bun,$midashi)
					= (0,0,0,0,0,1)
			}
			elsif (
				   $IDs->{$d->[1]} eq '<h3>'
				|| $IDs->{$d->[1]} eq '<H3>'
			){
				++$h3;
				($h4,$h5,$dan,$bun,$midashi)
					= (0,0,0,0,1)
			}
			elsif (
				   $IDs->{$d->[1]} eq '<h4>'
				|| $IDs->{$d->[1]} eq '<H4>'
			){
				++$h4;
				($h5,$dan,$bun,$midashi)=(0,0,0,1)
			}
			elsif (
				   $IDs->{$d->[1]} eq '<h5>'
				|| $IDs->{$d->[1]} eq '<H5>'
			){
				++$h5;
				($dan,$bun,$midashi)=(0,0,1)
			}

			                                          # DBに書き込み
			$temp .= "($bun2,$bun,$dan,$h5,$h4,$h3,$h2,$h1,$d->[1]),";
			unless ($last_tani eq "$bun2,$bun,$dan,$h5,$h4,$h3,$h2,$h1"){
				if (length($last_tani)){
					$temp_tani .= '('."$last_tani,$lc,$lw".'),';
				}
				$last_tani = "$bun2,$bun,$dan,$h5,$h4,$h3,$h2,$h1";
				$lc = 0;
				$lw = 0;
				++$c_t;
			}
			
			++$c;
			if ($c == $data_per_1ins){
				chop $temp;
				mysql_exec->do("
					INSERT INTO hyosobun
					(bun_idt, bun_id, dan_id, h5_id, h4_id, h3_id, h2_id, h1_id,hyoso_id)
					VALUES
						$temp
				",1);
				$temp = '';
				$c    = 0;
			}
			if ($c_t == $data_per_1ins){
				chop $temp_tani;
				mysql_exec->do("
					INSERT INTO hyosobun_t
					(bun_idt, bun_id, dan_id, h5_id, h4_id, h3_id, h2_id, h1_id, lc, lw)
					VALUES
						$temp_tani
				",1);
				$temp_tani = '';
				$c_t = 0;
			}

			if (
				   ($d->[2])
				and not ($IDs->{$d->[1]} =~ /<\/[Hh][1-5]>/o)
				and not ($IDs->{$d->[1]} =~ /<[Hh][1-5]>/o)
				and not ($d->[3])
			){
				$lc += $d->[2];
				++$lw;
			}

			if ($IDs->{$d->[1]} eq '。'){              # 句読点のチェック
				unless ($midashi){
					++$bun; ++$bun2; $maru = 1;
				}
			} else {
				$maru = 0;
			}
			if ($IDs->{$d->[1]} =~ /<\/[Hh][1-5]>/o){  # HTML終了タグのチェック
					$midashi = 0;
			}
		}
	$t->finish;
	}

	# 残りをDBに投入
	if ($temp){
		chop $temp;
		mysql_exec->do("
			INSERT INTO hyosobun
			   (bun_idt, bun_id, dan_id, h5_id, h4_id, h3_id, h2_id, h1_id,hyoso_id)
				VALUES
					$temp
		",1);
	}
	if ( ($lc) || ($lw) ){
		$temp_tani .= '('."$last_tani,$lc,$lw".'),';
	}
	if ($temp_tani){
		chop $temp_tani;
		mysql_exec->do("
			INSERT INTO hyosobun_t
			(bun_idt, bun_id, dan_id, h5_id, h4_id, h3_id, h2_id, h1_id, lc, lw)
			VALUES
				$temp_tani
		",1);
	}

	# インデックスを貼る
	mysql_exec->do("
		alter table hyosobun
			add index index1 (h1_id, h2_id, h3_id, h4_id, h5_id),
			add index index2 (bun_id, dan_id, bun_idt, hyoso_id),
			add index index4 (bun_idt)
	",1);
	mysql_exec->do("
		alter table hyosobun_t
			add index index1 (h1_id, h2_id, h3_id, h4_id, h5_id),
			add index index2 (bun_id, dan_id, bun_idt),
			add index index4 (bun_idt)
	",1);
	
	mysql_ready::heap->hyosobun;
}

sub hyosobun_sql{
	my $self = shift;
	my $d1   = shift;
	my $d2   = shift;

	my $sql ="
		SELECT rowdata.id, hghi.hyoso_id, hyoso.len, genkei.nouse
		FROM rowdata, hghi, genkei, hyoso
		WHERE
				    rowdata.hyoso  = hghi.hyoso
				AND rowdata.genkei = hghi.genkei
				AND rowdata.hinshi = hghi.hinshi
				AND hghi.genkei_id = genkei.id
				AND hghi.hyoso_id  = hyoso.id
				AND rowdata.id >= $d1
				AND rowdata.id <  $d2
		ORDER BY rowdata.id
	";

	#my $sql ="
	#	SELECT rowdata.id, hghi.hyoso_id,
	#	FROM rowdata, hghi
	#	WHERE
	#			    rowdata.hyoso  = hghi.hyoso
	#			AND rowdata.genkei = hghi.genkei
	#			AND rowdata.hinshi = hghi.hinshi
	#			AND rowdata.id >= $d1
	#			AND rowdata.id <  $d2
	#	ORDER BY rowdata.id
	#";
	return $sql;
}

#--------------------------------------#
#   タグ品詞の抽出語から<>を取り除く   #

sub tag_fix{
	my $self = shift;
	
	# 表層語テーブル
	
	my $h = mysql_exec->select("
		SELECT hyoso.id, hyoso.name
		FROM hyoso, genkei, hselection
		WHERE 
			    hyoso.genkei_id = genkei.id
			AND genkei.khhinshi_id = hselection.khhinshi_id
			AND hselection.name = \'タグ\'
	",1)->hundle;
	while (my $i = $h->fetch){
		my $name = $i->[1];
		chop $name; substr($name,0,1) = '';
		my $length = length($name);
		mysql_exec->do("
			UPDATE hyoso
			SET name = \'$name\', len = $length
			WHERE id = $i->[0]
		",1);
	}
	$h->finish;
	
	# 基本形テーブル
	
	my $k = mysql_exec->select("
		SELECT genkei.id, genkei.name
		FROM genkei, hselection
		WHERE 
			    genkei.khhinshi_id = hselection.khhinshi_id
			AND hselection.name = \'タグ\'
	",1)->hundle;
	
	while (my $i = $k->fetch){
		my $name = $i->[1];
		chop $name; substr($name,0,1) = '';
		mysql_exec->do("
			UPDATE genkei
			SET name = \'$name\'
			WHERE id = $i->[0]
		",1);
	}
	$k->finish;
}

#----------------------------#
#   平文格納テーブルを作製   #

sub rowtxt{
	my $self = shift;
	unless (
		mysql_exec->select("select max(bun_idt) from hyosobun",1)
			->hundle->fetch->[0]
	){ return 0; }
	$::project_obj->status_bun(1);

	mysql_exec->drop_table("bun_r");
	mysql_exec->do("create table bun_r(id int auto_increment primary key not null, rowtxt TEXT )",1);

	my ($c,$last,$values,$sql,$temp)
		=(0,1,'','INSERT into bun_r (rowtxt) VALUES ','');

	my $id = 1; my $tc = 0;
	while (1){
		my $h = mysql_exec->select(
			mysql_ready->rowtxt_sql($id, $id + $rows_per_once),
			1,
		)->hundle;
		unless ($h->rows > 0){
			last;
		}
		$id += $rows_per_once;

		while (my $i = $h->fetch){
			++$tc;
			if ($last == $i->[0]){
				$temp .= $i->[1]
			} else {
				# エラー・チェック
				if ( length($temp) > 65535 ){
					gui_errormsg->open(type => 'msg',msg => "32,767文字を超える文がありました。\nKH Coderを終了します。");
					exit;
				}
				unless ($last + 1 == $i->[0]){
					gui_errormsg->open(type => 'msg',msg => "「bun_r」テーブル作成中にデータの整合性が失われました。\nKH Coderを終了します。");
					exit;
				}
				
				$values .= "(\'$temp\'),";
				$temp = $i->[1];
				$last = $i->[0];
				++$c;
			}
			
			if ($c == $data_per_1ins){
				chop $values; mysql_exec->do("$sql $values",1);
				$c = 0; $values = '';
			}
		}
		$h->finish;
	}
	
	if ($values or $temp){
		if ($temp){
			$values .= "(\'$temp\'),";
		}
		chop $values; mysql_exec->do("$sql $values",1);
	}
}

sub rowtxt_sql{
	my $self = shift;
	my $d1   = shift;
	my $d2   = shift;

	my $sql ="
		SELECT hyosobun.bun_idt, hyoso.name
		FROM hyosobun, hyoso
		WHERE 
			    hyosobun.hyoso_id = hyoso.id
			AND hyosobun.id >= $d1
			AND hyosobun.id < $d2
		ORDER BY hyosobun.id
	";

	return $sql;
}

#--------------------------------------------------#
#    各集計単位（H1, H2, H3,,,）のテーブルを作製   #


sub tanis{
	if (mysql_exec->select("select max(bun_idt) from hyosobun",1)->hundle->fetch->[0]){
		# 文単位2
		mysql_exec->drop_table("bun");
		mysql_exec->do("
			create table bun(
				id int auto_increment primary key not null,
				bun_id int,
				dan_id int,
				h5_id int,
				h4_id int,
				h3_id int,
				h2_id int,
				h1_id int
			)
		",1);
		mysql_exec->do("
			INSERT INTO bun (bun_id, dan_id, h5_id, h4_id, h3_id, h2_id, h1_id)
			SELECT bun_id, dan_id, h5_id, h4_id, h3_id, h2_id, h1_id
			FROM hyosobun_t
			GROUP BY bun_idt
			ORDER BY bun_idt
		",1);
		mysql_exec->do("ALTER TABLE bun ADD INDEX index1 (bun_id)",1);
		mysql_exec->do("ALTER TABLE bun ADD INDEX index2 (dan_id)",1);
		mysql_exec->do("ALTER TABLE bun ADD INDEX index3 (h5_id)",1);
		mysql_exec->do("ALTER TABLE bun ADD INDEX index4 (h4_id)",1);
		mysql_exec->do("ALTER TABLE bun ADD INDEX index5 (h3_id)",1);
		mysql_exec->do("ALTER TABLE bun ADD INDEX index6 (h2_id)",1);
		mysql_exec->do("ALTER TABLE bun ADD INDEX index7 (h1_id)",1);
		mysql_exec->do("
			ALTER TABLE bun ADD INDEX index8 (
				bun_id,dan_id,h5_id,h4_id,h3_id,h2_id,h1_id
			)
		",1);
		mysql_ready::doclength->make_each('bun');
	}
	
	
	# 段落単位
	if(mysql_exec->select("select max(dan_id) from hyosobun",1)->hundle->fetch->[0]){
		$::project_obj->status_dan(1);
		mysql_exec->drop_table("dan");
		mysql_exec->do("
			create table dan(
				id int auto_increment primary key not null,
				dan_id int,
				h5_id int,
				h4_id int,
				h3_id int,
				h2_id int,
				h1_id int
			)
		",1);
		mysql_exec->do("
			INSERT INTO dan (dan_id, h5_id, h4_id, h3_id, h2_id, h1_id)
			SELECT dan_id, h5_id, h4_id, h3_id, h2_id, h1_id
			FROM hyosobun_t
			WHERE dan_id > 0
			GROUP BY dan_id, h5_id, h4_id, h3_id, h2_id, h1_id
			ORDER BY h1_id, h2_id, h3_id, h4_id, h5_id, dan_id
		",1);
		mysql_exec->do("ALTER TABLE dan ADD INDEX index2 (dan_id)",1);
		mysql_exec->do("ALTER TABLE dan ADD INDEX index3 (h5_id)",1);
		mysql_exec->do("ALTER TABLE dan ADD INDEX index4 (h4_id)",1);
		mysql_exec->do("ALTER TABLE dan ADD INDEX index5 (h3_id)",1);
		mysql_exec->do("ALTER TABLE dan ADD INDEX index6 (h2_id)",1);
		mysql_exec->do("ALTER TABLE dan ADD INDEX index7 (h1_id)",1);
		mysql_exec->do("
			ALTER TABLE dan ADD INDEX index8 (
				dan_id,h5_id,h4_id,h3_id,h2_id,h1_id
			)
		",1);
		mysql_ready::doclength->make_each('dan');
	}
	# h5単位
	if(mysql_exec->select("select max(h5_id) from hyosobun",1)->hundle->fetch->[0]){
		$::project_obj->status_h5(1);
		mysql_exec->drop_table("h5");
		mysql_exec->do("
			create table h5(
				id int auto_increment primary key not null,
				h5_id int,
				h4_id int,
				h3_id int,
				h2_id int,
				h1_id int
			)
		",1);
		mysql_exec->do("
			INSERT INTO h5 (h5_id, h4_id, h3_id, h2_id, h1_id)
			SELECT h5_id, h4_id, h3_id, h2_id, h1_id
			FROM hyosobun_t
			WHERE h5_id > 0
			GROUP BY h5_id, h4_id, h3_id, h2_id, h1_id
			ORDER BY h1_id, h2_id, h3_id, h4_id, h5_id
		",1);
		mysql_exec->do("ALTER TABLE h5 ADD INDEX index3 (h5_id)",1);
		mysql_exec->do("ALTER TABLE h5 ADD INDEX index4 (h4_id)",1);
		mysql_exec->do("ALTER TABLE h5 ADD INDEX index5 (h3_id)",1);
		mysql_exec->do("ALTER TABLE h5 ADD INDEX index6 (h2_id)",1);
		mysql_exec->do("ALTER TABLE h5 ADD INDEX index7 (h1_id)",1);
		mysql_exec->do("
			ALTER TABLE h5 ADD INDEX index8 (
				h5_id,h4_id,h3_id,h2_id,h1_id
			)
		",1);
		mysql_ready::doclength->make_each('h5');
	}
	# h4単位
	if(mysql_exec->select("select max(h4_id) from hyosobun",1)->hundle->fetch->[0]){
		$::project_obj->status_h4(1);
		mysql_exec->drop_table("h4");
		mysql_exec->do("
			create table h4(
				id int auto_increment primary key not null,
				h4_id int,
				h3_id int,
				h2_id int,
				h1_id int
			)
		",1);
		mysql_exec->do("
			INSERT INTO h4 (h4_id, h3_id, h2_id, h1_id)
			SELECT h4_id, h3_id, h2_id, h1_id
			FROM hyosobun_t
			WHERE h4_id > 0
			GROUP BY h4_id, h3_id, h2_id, h1_id
			ORDER BY h1_id, h2_id, h3_id, h4_id
		",1);
		mysql_exec->do("ALTER TABLE h4 ADD INDEX index4 (h4_id)",1);
		mysql_exec->do("ALTER TABLE h4 ADD INDEX index5 (h3_id)",1);
		mysql_exec->do("ALTER TABLE h4 ADD INDEX index6 (h2_id)",1);
		mysql_exec->do("ALTER TABLE h4 ADD INDEX index7 (h1_id)",1);
		mysql_exec->do("
			ALTER TABLE h4 ADD INDEX index8 (
				h4_id,h3_id,h2_id,h1_id
			)
		",1);
		mysql_ready::doclength->make_each('h4');
	}
	# h3単位
	if(mysql_exec->select("select max(h3_id) from hyosobun",1)->hundle->fetch->[0]){
		$::project_obj->status_h3(1);
		mysql_exec->drop_table("h3");
		mysql_exec->do("
			create table h3(
				id int auto_increment primary key not null,
				h3_id int,
				h2_id int,
				h1_id int
			)
		",1);
		mysql_exec->do("
			INSERT INTO h3 (h3_id, h2_id, h1_id)
			SELECT h3_id, h2_id, h1_id
			FROM hyosobun_t
			WHERE h3_id > 0
			GROUP BY h3_id, h2_id, h1_id
			ORDER BY h1_id, h2_id, h3_id
		",1);
		mysql_exec->do("ALTER TABLE h3 ADD INDEX index5 (h3_id)",1);
		mysql_exec->do("ALTER TABLE h3 ADD INDEX index6 (h2_id)",1);
		mysql_exec->do("ALTER TABLE h3 ADD INDEX index7 (h1_id)",1);
		mysql_exec->do("
			ALTER TABLE h3 ADD INDEX index8 (
				h3_id,h2_id,h1_id
			)
		",1);
		mysql_ready::doclength->make_each('h3');
	}
	# h2単位
	if(mysql_exec->select("select max(h2_id) from hyosobun",1)->hundle->fetch->[0]){
		$::project_obj->status_h2(1);
		mysql_exec->drop_table("h2");
		mysql_exec->do("
			create table h2(
				id int auto_increment primary key not null,
				h2_id int,
				h1_id int
			)
		",1);
		mysql_exec->do("
			INSERT INTO h2 (h2_id, h1_id)
			SELECT h2_id, h1_id
			FROM hyosobun_t
			WHERE h2_id > 0
			GROUP BY h2_id, h1_id
			ORDER BY h1_id, h2_id
		",1);
		mysql_exec->do("ALTER TABLE h2 ADD INDEX index6 (h2_id)",1);
		mysql_exec->do("ALTER TABLE h2 ADD INDEX index7 (h1_id)",1);
		mysql_exec->do("
			ALTER TABLE h2 ADD INDEX index8 (
				h2_id,h1_id
			)
		",1);
		mysql_ready::doclength->make_each('h2');
	}
	# h1単位
	if(mysql_exec->select("select max(h1_id) from hyosobun",1)->hundle->fetch->[0]){
		$::project_obj->status_h1(1);
		mysql_exec->drop_table("h1");
		mysql_exec->do("
			create table h1(
				id int auto_increment primary key not null,
				h1_id int
			)
		",1);
		mysql_exec->do("
			INSERT INTO h1 (h1_id)
			SELECT h1_id
			FROM hyosobun_t
			WHERE h1_id > 0
			GROUP BY h1_id
			ORDER BY h1_id
		",1);
		mysql_exec->do("ALTER TABLE h1 ADD INDEX index7 (h1_id)",1);
		mysql_ready::doclength->make_each('h1');
	}
}

#--------------#
#   アクセサ   #
#--------------#

sub length{
	my $self   = shift;
	my $name   = shift;
	my $length = shift;
	
	if ($length){
		$self->{length}{$name} = $length;
		return $self;
	} else {
		if ($self->{length}{$name}){
			return $self->{length}{$name};
		} else {
			return 255;
		}
	}
}

1;


__END__

#if ($::config_obj->sqllog){                    # coder_data/*_fm.csv出力
#	my $f = $::project_obj->file_FormedText;    # デバッグモード時のみ
#	my $d = '';
#	my $h = mysql_exec->select("select h1_id, h2_id, h3_id, h4_id, h5_id, dan_id, bun_id, bun_idt, hyoso.name from hyosobun, hyoso where hyosobun.hyoso_id = hyoso.id",1)->hundle;
#	my $last = -1;
#	while (my $r = $h->fetch){
#		if ( $r->[7] != $last){
#			$last = $r->[7];
#			$d .= "\n";
#			$d .= "$r->[0],$r->[1],$r->[2],$r->[3],$r->[4],$r->[5],$r->[6],$r->[7],$r->[8]";
#		} else {
#			$d .= $r->[8];
#		}
#	}
#	substr($d,0,1) = '';
#	open (FT,">$f") or die;
#	print FT $d;
#	close (FT);
#	use kh_jchar;
#	kh_jchar->to_sjis($f);
#}
