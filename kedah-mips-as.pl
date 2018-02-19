#!/usr/bin/perl

use Getopt::Std;
use Math::BigInt;


$ver = '0.0.8';

die <<EOT unless @ARGV && !grep { /^--?h|\?/ } @ARGV;

  Kedah MIPS ассемблер, версия $ver
  Программа ассемблирует файл инструкций процессора MIPS в двоичный образ памяти.

  Синтаксис вызова: mi [ключи] <имя файла>[.mi] [<имя выходного файла>[.bin|.txt|.hex]]
  Ключи:

    -t предписывает формировать вместо двоичного образа памяти его текстовый листинг.
    -x выводить в листинг только адреса и шестнадцатиричные значения слов (только для загрузки). При этом листинг имеет расширение .hex
    -p <адрес> задает адрес загрузки (по умолчанию 0).
    -8 означает то же, что -p 0x80000000
    -r означает то же, что -p 0xBFC00000  (адрес reset)
    -s  - не выводить предупреждений

  Синтаксис ассемблера практически отсутствует (см. образцы файлов .mi )

  Понимает метки (в командах джампов и бранчей), числа в разных системах исчисления, псевдоинструкции .word и .dword
  Можно использовать метки переменных в командах обращения к памяти и псевдоинструкцию  .base <метка базирования>.
  Можно также использовать метки (вместо чисел) в псевдоинструкции .word; при этом метки не должны совпадать с именами инструкций.
  Можно определять константы (т.е. макросы без параметров), через знак равенства.
  Разрешаются также арифметические выражения с метками, в том числе в непосредственных операндах инструкций.

  Понимает псевдоинструкции .ascii и .asciiz, при этом допускаются любые строки, допустимые в Perl. Длины строк выравниваются до 4 байтов.
  Понимает псевдоинструкцию .org (которая, однако, в ассемблере SDE называется иначе). 
  Понимает псевдоинструкцию .align <n> (кроме .align 0).
  Пустоты, вызванные .org и .align заполняются нулями в .bin, но не заполняются в .txt и .hex 
  Для инструкций сложения с непосредственным операндом можно опускать регистр источника.

  Изображение чисел в системах исчисления:          (числа только положительные)
  двоичной:             0b01010101 или 01010101b
  восьмеричной:         должно начинаться с нуля    (только в операндах инструкций)
  шестнадцатиричной:    0x1234ABCD или 1234ABCDh

EOT



#    Обработка ключа -8 и ключа -r:

$argv_string = join ' ', @ARGV;
$argv_string =~ s/-8/-p 0x80000000/;
$argv_string =~ s/-r/-p 0xBFC00000/;
@ARGV = split ' ', $argv_string;




#    Getopt любит, чтобы ключи в списке параметров стояли первыми:

while( $ARGV[ -1 ] =~ /^-/ || $ARGV[ -2 ]  eq '-p' ){ unshift @ARGV, (pop @ARGV); } 


our ($opt_x, $opt_t, $opt_p, $opt_s);
getopts('sxtp:');

$ip_load = ($opt_p =~ /^0/ ? oct $opt_p : $opt_p) || 0;


#
# При отсутствии директивы .base смещения в командах обращения к памяти будем базировать загрузочным адресом:
#

$base_label = 'load_addr_pseudo_label';  $label{ $base_label } = $ip_load + 0;



if( $ARGV[1] ){               #    Формируем выходное имя 
    $ft_name = $ARGV[1];
    $ft_name .= ($opt_t ? '.txt' : '.bin') unless $ft_name =~ /\./;
    pop @ARGV;
}
else
{   $ft_name = $ARGV[0];

    if( $opt_x ){
        $ft_name .= '.hex' unless $ft_name =~ s/(\.mi$)|(\.mips$)/\.hex/;
    }
    elsif( $opt_t ){
        $ft_name .= '.txt' unless $ft_name =~ s/(\.mi$)|(\.mips$)/\.txt/;
    }
    else
    {
        $ft_name .= '.bin' unless $ft_name =~ s/(\.mi$)|(\.mips$)/\.bin/;
    }
}



#   Подбираем расширение входного имени, пока не встретим существующий файл

for $enh ('', '.mips', '.mi'){
    if( -e $ARGV[0] . $enh ){  $ARGV[0] .= $enh; break; }
}

open FT, ">$ft_name";  binmode FT unless $opt_t || $opt_x;


binmode FT;





#
# Разделяет строку команды на отдельные поля и приводит их к удобному для дальнейшей обработки виду.
# Некоторые из них - например, смещения перед базовыми регистрами в скобках - могут быть сложными арифметическими выражениями
# и содержать пробелы. Их надо выделять с особой тщательностью
#

sub codeline_split {

    my $c = shift;
    my @a = ();

    $c =~ s/#.*$//;     # убираем комментарии
    $c =~ s/\s+$//;     # убираем завершающие пробелы
    $c =~ s/\$//g;      # доллар перед номером регистра игнорируем


    # Если имя инструкции заканчивается на I или IU, то все, что идет от последней запятой до конца строки, может быть
    # непосредственным операндом, представленным (в том числе) в виде сложного арифметического выражения.
    # Отделим его от сроки и поместим в единственное поле массива @a:

    if( $c =~/^\w+IU?\s/i ){

        if( $c =~ s/,\s*([^,]+)$// ){  $a[0] = $1;  }
    }

    # Если строка завершается парой скобок с регистром между ними - значит, это базовый регистр, а перед ним идет смещение.
    # (Правда, иногда вместо смещения это будет индекс, но в этом случае это будет просто число, и обрабатывается точно так же).
    # Отделим их от всего остального и поместим в два отдельных поля в @a:

    elsif( $c =~ s/ \s* \( \s* (0x[\da-fA-F]+|[\da-fA-F]+h|0b[01]+|[01]+b|\d+) \s* \)$//x ){

    $a[1] = $1;     # базовый регистр, шестнадцатиричный, двоичный или десятичный

    # Если в строке имеется запятая, как в LB rt, offset( base ) или в PREF hint, offset( base ), то выражение для offset
    # находится после запятой.
    # Если же запятой нет, как в SYNCI offset( base ), то оно идет после первого же пробела:

    if( $c =~ /,/ ){    $c =~ s/,\s*(.+)//;     $a[0] = $1;    }
    else           {    $c =~ s/\S+\s+(.+)//;   $a[0] = $1;    }
    }

    # Остальное обрабатываем стандартно:

    $c =~ s/,/ /g;      # запятые игнорируем
    $c =~ s/\(|\)/ /g;  # скобки тоже

    # Если в сложении с непосредственным операндом указан только регистр приемника, считаем его по умолчанию и регистром источника:
    if( $c =~ /ADDIU?\s+(\S+)\s*$/i ){   my $x = $1;  $c =~ s/$x/$x $x/;  }

    return split(/\s+/, $c) , @a;
}



#
# В полях инструкции можно писать двоичные, десятичные и 16-чные числа; функция приводит их к стандартному виду
#

sub field_decode {     

    my $v = shift;

    return $v if $label{ $v };   # метки декодировать нельзя - они должны декодироваться в зависимости от команды, в которой находятся

    return $v if $v =~ /\W/;     # небуква и нецифра - признак арифметического выражения, они тоже декодируются отдельно

    if( $v !~ m/^0x/i ){

        $v = '0x' . $v if $v =~ s/h$//;         # вместо 0x00FF можно писать 00FFh
        $v = '0b' . $v if $v =~ s/b$//;         # вместо 0b0011 можно писать 0011b
    }

    $v = oct $v if $v =~ /^0/;
    $v;
}



#
# Обрабатывает поля смещений в командах обращения к памяти.
# Такое поле может быть числом, меткой, или арифметическим выражением, в том числе включающем числа и метки.
# Если число совпадает с одной из имеющихся меток, оно должно восприниматься как число, а не как метка
#

sub eval_offset_expr {

    my $v = shift;

    # Здесь придется частично повторять работу функции field_decode, потому что числа в арифметических выражениях она не обрабатывает.
    # Преобразуем числа в стандартный вид: 

    $v =~ s/\b0x([\da-fA-F]+)\b/ hex $1 /ge;    # шестнадатиричные в стандартной кодировке
    $v =~ s/\b([\da-fA-F]+)h\b/  hex $1 /ge;    # шестнадцатиричные в кодировке 1234h
    $v =~ s/\b(0b[01]+)\b/     $1 /gee;         # двоичные в стандартной кодировке
    $v =~ s/\b([01]+)b\b/ '0b'.$1 /gee;         # двоичные в кодировке 0101b
    $v =~ s/\b(0\d+)\b/ oct $1 /ge;             # восьмеричные

    # Заменяем метки их смещениями относительно базовой:

    $v =~ s/\b(?!\d)(\w+)/ defined $label{ $1 } ? $label{ $1 } - $label{ $base_label } : die "wrong label \"$1\" in: $_\n" /ge;

    return eval $v;
}




#
# Расширение знака 32-разрядного BigInt
#

$mask64  = (Math::BigInt->new(1) << 64) - 1;
$signes32 = $mask64 ^ 0xFFFFFFFF;

sub sign_extend32 {  if( $_[0] & 0x80000000 ){  $_[0]->bior( $signes32 );    }
                     else                    {  $_[0]->band( 0xFFFFFFFF );   }
}



#
#
#

sub bits64 {                                       
    ( my $b = $_[0]->as_bin() ) =~ s/0b//;        # работает с объектами Math::BigInt
    ( my $p = sprintf "%64s", $b ) =~ s/ /0/g;
    $p;
}

sub hex16 {
    ( my $h = $_[0]->as_hex() ) =~ s/0x//;        # работает с объектами Math::BigInt
    ( my $p = sprintf "%16s", $h ) =~ s/ /0/g;
    uc $p;
}



sub bits3 {
    (my $b = sprintf "%3b", $_[0]) =~ s/ /0/g;
    substr $b, -3;
}

sub bits5 {
    (my $b = sprintf "%5b", $_[0]) =~ s/ /0/g;
    substr $b, -5;
}

sub bits10 {
    (my $b = sprintf "%10b", $_[0]) =~ s/ /0/g;
    substr $b, -10;
}

sub bits16 {
    (my $b = sprintf "%16b", $_[0]) =~ s/ /0/g;
    substr $b, -16;
}

sub bits20 {
    (my $b = sprintf "%20b", $_[0]) =~ s/ /0/g;
    substr $b, -20;
}

sub bits26 {
    (my $b = sprintf "%26b", $_[0]) =~ s/ /0/g;
    substr $b, -26;
}



sub hex8 {
    (my $h = sprintf "%8X", $_[0]) =~ s/ /0/g;
    substr $h, -8;
}



sub pack_instruction {

    my $v = reverse join '', @_;
    pack 'b32', $v;

    # если нужна BigEndianess, то надо еще reverse
}



# Все транслируемые инструкции:

for( qw/  ADD ADDU DADD DADDU DSUB DSUBU ADDI DADDI DADDIU ADDIU ANDI B BAL BEQ BEQL BNEL BNE BGEZ BGEZAL BGEZALL BGEZL BGTZL BGTZ BLEZL BLEZ BLTZ BLTZAL 
      BLTZALL BLTZL DSRL SRA SRAV DEXT DEXTM DEXTU EXT DINS DINSM DINSU INS ROTR DROTR DROTR DROTRV ROTRV DSRA DSRA DSRAV J JAL LB LD LUI SLLV DSLLV
      SRLV DSRLV OR ORI SB SD SLL DSLL DSLL DSRL SRL SUB BREAK CLO CLZ DCLO DCLZ DDIV DDIVU DERET EI DI DSBH DSHD WSBH DIV DIVU DMFC DMTC DMULT DMULTU
      ERET JALR JR LBU LDL LDR LH LHU LL LLD LW LWL LWR LWU MADD MADDU MFC MFHI MFLO MOVN MOVZ MSUB MSUBU MTC MTHI MTLO MUL MULT MULTU NOR AND PREF 
      PREFX SC SCD SDL SDR SEB SEH SH SLT SLTI SLTIU SLTU SSNOP SUBU SW SWL SWR SYNC SYSCALL TEQ TEQI TGE TGEI TGEIU TGEU TLBP TLBR TLBWI TLBWR TLT 
      TLTI TLTIU TLTU TNE TNEI WAIT XOR XORI EHB NOP / 
){  
    $ihash{ $_ } = 1;  
}




#
# Нулевой проход - собираем хеш меток, чтобы на первом проходе они правильно обрабатывались в .word
# Здесь же формируется хеш констант:
#

@argv_copy = @ARGV;

while(<>){

    chomp;

    if( /^\s*(\w+):/ ){    
                   
        if( $ihash{ uc $1 } ){   printf "\n WARNING: the label '%s' may be confused with instruction name '%s'\n\n", $1, uc $1  if !$opt_s;   }
        else
        {
            $pure_label{ $1 } = 1  unless $1 =~ /^\d+$/;            # здесь будут только метки, которые нельзя перепутать с инструкциями или числами
        } 
    }

    s/\s*#.*//;

    if( /^\s*(\w+)\s*=\s*(.+)/ ){   $const{ qr/$1/ } = $2;   }
}




#
# Первый проход - вычисление адресов меток. Он сделан на основе второго, но убрано все, что касается генерации
#

@ARGV = @argv_copy;
$word_size = 8;         # по умолчанию числовые данные считаются .dword
$ip = $ip_load;

while(<>){

    chomp;

    if( /^\s*$/ or /^\s*#/ ){             # обработка комментариев и пустых строк
        next;
    }


    if( /^\s*\w+\s*=/ ){
        next;
    }
    else
    {

P1_CONST_REDO:
        for $t (keys %const){
            goto P1_CONST_REDO if s/\b$t\b/$const{ $t }/;        # заменяем константы их значениями
        }
    }


    if( s/^\s*([^#\"]+):// ){             # обработка меток
        $label{ $1 } = $ip;
        $last_label = $1;
        redo;
    }

    s/^\s+//;                             # убираем левые поля


    if( /^\.base\s+(\S+)/ ){  next;  }    # псевдокоманда .base  обрабатывается на втором проходе


    # псевдокоманда .ascii

    if( /^\.ascii\s+(.+)/ ){

        # eval делает всю работу: обрабатывает двойные и одиночные кавычки, бэкслеши, спецсимволы и комментарии:

        my $v = eval $1;
        my $l = length $v;

        $l++ while $l % 4;
        $ip += $l;
        next;
    }

    # псевдокоманда .asciiz

    if( /^\.asciiz\s+(.+)/ ){

        # eval делает всю работу: обрабатывает двойные и одиночные кавычки, бэкслеши, спецсимволы и комментарии:

        my $v = eval $1;
        my $l = length( $v ) + 1;

        $l++ while $l % 4;
        $ip += $l;
        next;
    }


    #   строка, содержащая одно число (64 или 32-разрядное) и, возможно, комментарии:

    if( /^(0[xX][\da-fA-F]+)/ || /^(0[bB][01]+)/ || /^([\da-fA-F]+h)/ || /^([01]+b)/ || /^(\d+)/ || (/^(\w+)/ && $pure_label{ $1 }) ){
        $match = $1;


        # Если число 64-разрядное, выровняем его, и скорректируем его метку, если там была метка:

        if( $ip % $word_size ){
            if( $label{ $last_label } == $ip ){
                $label{ $last_label } += 4;
            }
            $ip += 4;
        }


        $ip += $word_size;

        s/^$match[,\s]*//;              # убираем только что обработанное и запятые с пробелами за ним
        redo unless /^\s*(#.*)?$/;      # если там осталось что-то кроме комментариев - обрабатываем заново
        next;
    }


    #   псевдокоманда .dword обрабатывается так же, как первое число в строке чисел, но пишет только в текстовый файл:
    #   (и не увеличивает счетчик адресов)
    if( /^\.dword/i ){
        s/^\.dword,?\s*//i;
        $word_size = 8;
        redo;
    }

    #   то же самое для .word:

    if( /^\.word/i ){
        s/^\.word,?\s*//i;
        $word_size = 4;
        redo;
    }


    # Псевдокоманду .align делаем через .org:  (.align 0 как отключение выравнивания чисел не понимает)

    if( /\.align \s+ ([0-9A-Fx]+)/ix ){
    
        $align_deg = $1;
        $align_deg = oct lc $align_deg if $align_deg =~ m/^0x/i;

        $align_step = 1 << $align_deg;

        my $v = $ip % $align_step;

        $_ = sprintf "  .org 0x%08X", ($ip - $ip_load + ($v ? $align_step - $v : 0));
    }

    
    # Псевдокоманда  .org  вставляет NOP'ы, пока не дойдет до заданного адреса:

    if( /\.org \s+ ([0-9A-Fx]+)/ix ){

        $next_org_ip = $1;
        $next_org_ip = oct lc $next_org_ip if $next_org_ip =~ m/^0x/i;

        $next_org_ip += $ip_load;    # ключ -p <адрес> смещает .org на этот адрес

        $ip = $next_org_ip;
        next;
    }




    $ip += 4;
}           




#
# Второй проход - генерирующий
#

@ARGV = @argv_copy;
$word_size = 8;         # по умолчанию числовые данные считаются .dword
$ip = $ip_load;

while(<>){

    chomp;

    if( /^\s*$/ or /^\s*#/ ){           # обработка комментариев и пустых строк
        if( $opt_t ){
            print FT "$_\n";
        }
        next;
    }

    s/^\s+//;                           # убираем левые поля

    $printable_string = $_;             # сама $_ будет подвергаться макроподстановкам


    if( /^\s*\w+\s*=/ ){
        if( $opt_t ){       print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";       }
        next;
    }
    else
    {

P2_CONST_REDO:
        for $t (keys %const){                 
            goto P2_CONST_REDO if s/\b$t\b/$const{ $t }/;      # заменяем константы их значениями
        }
    }


    if( s/^\s*([^#\"]+):// ){           # обработка меток
        if( $opt_t ){
            print FT "$1:\n";
        }
        redo  if /\S/;                  # если в строке что-то осталось, обработаем ее еще раз
        next;                           # иначе перейдем к следующей
    }



    # псевдокоманда .base

    if( /^\.base\s+(\S+)/ ){

    $base_label = $1;

    if( $opt_t ){       print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";       }                        
    next;
    }


    # псевдокоманда .ascii здесь мощнее, чем в оригинале: это Perl!

    if( /^\.ascii\s+(.+)/ ){

        # eval делает всю работу: обрабатывает двойные и одиночные кавычки, бэкслеши, спецсимволы и комментарии:

        my $v = eval $1;

        $v .= "\0" while length( $v ) % 4;


        if(    $opt_x ){                                                   }
        elsif( $opt_t ){       print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";       }                        
        
        # Теперь преобразуем строку в последовательность 32-разрядных шестнадцатиричных цифр, и пусть они обрабатываются как цифры:
        $_ = join ' ', map { sprintf( '0x%08X', $_ ) } unpack "L*", $v;
        $word_size = 4;
        $string_of_numbers = 1;
    }


    # псевдокоманда .asciiz

    if( /^\.asciiz\s+(.+)/ ){

        # eval делает всю работу: обрабатывает двойные и одиночные кавычки, бэкслеши, спецсимволы и комментарии:

        my $v = eval( $1 ) . "\0";

        $v .= "\0" while length( $v ) % 4;

        if(    $opt_x ){                                                   }
        elsif( $opt_t ){       print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";       }

        # Теперь преобразуем строку в последовательность 32-разрядных шестнадцатиричных цифр, и пусть они обрабатываются как цифры:
        $_ = join ' ', map { sprintf( '0x%08X', $_ ) } unpack "L*", $v;
        $word_size = 4;
        $string_of_numbers = 1;
    }



    #   строка, содержащая одно число (64 или 32-разрядное) и, возможно, комментарии:

    if( /^(0[xX][\da-fA-F]+)/ || /^(0[bB][01]+)/ || /^([\da-fA-F]+h)/ || /^([01]+b)/ || /^(\d+)/ || (/^(\w+)/ && $pure_label{ $1 }) ){

        $v = $1;   $match = $v;

        if( $pure_label{ $v } ){

            $v = $label{ $v };        # метка может употребляться в .word или .dword, в этом случае она означает собственный адрес

            $v = sign_extend32( Math::BigInt->new( $v ))  if $word_size == 8;

        }
        elsif( $v !~ m/^0x/i )
        {
            $v = '0x' . $v if $v =~ s/h$//;
            $v = '0b' . $v if $v =~ s/b$//;
        }

        $vq = Math::BigInt->new( $v );          # не понимает восьмеричных и отрицательных чисел !!!


        # Прежде, чем выводить число, выровняем его адрес, если оно 64-разрядное:

        if( $ip % $word_size ){

            if( $opt_t || $opt_x ){

                $ip_hex = hex8 $ip;
                print FT "$ip_hex / 00000000\n";
            }
            else
            {
                $vb_lo_p = pack_instruction  '00000000000000000000000000000000';
                print FT $vb_lo_p;
            }
            $ip += 4;

        }


        # Теперь выводим собственно число:

        if( $opt_t || $opt_x ){

            $ip_hex = hex8 $ip;

            if( $word_size == 8){  $vqh = hex16 $vq; }
            else                {  $vqh = hex8  $vq; }

            # строку чисел распечатываем только один раз:
            if( $string_of_numbers || $opt_x ){   print FT "$ip_hex / $vqh\n";                 }
            else                              {   print FT "$ip_hex / $vqh  \t\t\t\t\t$printable_string\n";   }
        }
        else
        {
            $vb = bits64 $vq;

            $vb_lo = substr $vb, 32;
            $vb_hi = substr $vb, 0, 32              if $word_size == 8;
    
            $vb_lo_p = pack_instruction  $vb_lo;
            $vb_hi_p = pack_instruction  $vb_hi     if $word_size == 8;

            print FT $vb_lo_p;
            print FT $vb_hi_p                       if $word_size == 8;

        }
        $ip += $word_size;


        #   Может быть, там есть еще числа - через запятую или через пробел:

        s/^$match[,\s]*//;              # убираем только что обработанное и запятые с пробелами за ним
        
        unless( /^\s*(#.*)?$/ ){
            $string_of_numbers = 1;
            redo;                       # если там осталось что-то кроме комментариев - обрабатываем заново
        }
        $string_of_numbers = 0;
        next;
    }



    #   псевдокоманда .dword обрабатывается так же, как первое число в строке чисел, но пишет только в текстовый файл:
    #   (и не увеличивает счетчик адресов)

    if( /^\.dword/i ){
        if( $opt_t ){   print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";    }

        s/^\.dword,?\s*//i;
        $word_size = 8;

        unless( /^\s*(#.*)?$/ ){
            $string_of_numbers = 1;
            redo;                       # если там осталось что-то кроме комментариев - обрабатываем заново
        }
        $string_of_numbers = 0;
        next;
    }


    #   то же самое для .word:

    if( /^\.word/i ){
        if( $opt_t ){   print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";    }

        s/^\.word,?\s*//i;
        $word_size = 4;

        unless( /^\s*(#.*)?$/ ){
            $string_of_numbers = 1;
            redo;                       # если там осталось что-то кроме комментариев - обрабатываем заново
        }
        $string_of_numbers = 0;
        next;
    }


    # Псевдокоманду .align делаем во втором проходе напрямую; .align 0 как отключение выравнивания чисел не понимает

    if( /\.align \s+ ([0-9A-Fx]+)/ix ){
        if( $opt_t ){   print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";    }
    
        $align_deg = $1;
        $align_deg = oct lc $align_deg if $align_deg =~ m/^0x/i;

        $align_step = 1 << $align_deg;
        $v = $ip % $align_step;

        $next_align_ip = $ip + ($v ? $align_step - $v : 0);

        if( $opt_t || $opt_x )
        {
            $instr_hex  =  hex8             0b00000000000000000000000000000000;

            while( $ip < $next_align_ip ){

                $ip_hex = hex8 $ip;
                print FT "$ip_hex / $instr_hex\n";
                $ip += 4;
            }
        }
        else
        {
            $instr      =  pack_instruction  '00000000000000000000000000000000';

            while( $ip < $next_align_ip ){

                print FT $instr;
                $ip += 4;
            }
        }
        next;
    }
    

    # Псевдокоманда  .org  вставляет NOP'ы, пока не дойдет до заданного адреса:

    if( /\.org \s+ ([0-9A-Fx]+)/ix ){

        if( $opt_t ){       print FT "\t   \t\t  \t\t\t\t\t$printable_string\n";       }                        

        $next_org_ip = $1;
        $next_org_ip = oct lc $next_org_ip if $next_org_ip =~ m/^0x/i;


        $next_org_ip += $ip_load;    # ключ -p <адрес> смещает .org на этот адрес


        unless( $opt_t || $opt_x ){
            $instr = pack_instruction '00000000000000000000000000000000';
        
            while( $ip < $next_org_ip ){  print FT $instr;  $ip += 4;  }
        }

        $ip = $next_org_ip;
        next;
    }



    ($a, @f) = codeline_split( $_ );

    $a = uc $a;
    @f = map { field_decode( $_ ) } @f;



    if( $a eq 'ADD' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '100000';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '100000';         
    }
    elsif( $a eq 'ADDU' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '100001';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '100001';
    }
    elsif( $a eq 'DADD' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '101100';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '101100';
    }
    elsif( $a eq 'DADDU' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '101101';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '101101';
    }
    elsif( $a eq 'DSUB' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '101110';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '101110';
    }
    elsif( $a eq 'DSUBU' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '101111';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '101111';
    }
    elsif( $a eq 'ADDI' ){

        $op  = '001000';

    $f[2] = eval_offset_expr $f[2];

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $imm = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $imm;
        $instr_bin = join '_',    $op, $rs, $rt, $imm;

    }
    elsif( $a eq 'DADDI' ){

        $op  = '011000';

    $f[2] = eval_offset_expr $f[2];

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $imm = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $imm;
        $instr_bin = join '_',    $op, $rs, $rt, $imm;

    }
    elsif( $a eq 'DADDIU' ){

        $op  = '011001';

    $f[2] = eval_offset_expr $f[2];

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $imm = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $imm;
        $instr_bin = join '_',    $op, $rs, $rt, $imm;

    }
    elsif( $a eq 'ADDIU' ){

        $op  = '001001';

    $f[2] = eval_offset_expr $f[2];

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $imm = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $imm;
        $instr_bin = join '_',    $op, $rs, $rt, $imm;

    }
    elsif( $a eq 'ANDI' ){

        $op  = '001100';

    $f[2] = eval_offset_expr $f[2];

        $rs   = bits5   $f[1];
        $rt   = bits5   $f[0];
        $imm  = bits16  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $imm;
        $instr_bin = join '_',    $op, $rs, $rt, $imm;

    }
    elsif( $a eq 'B' ){

        $op  = '000100';

        $f[0] =  ($label{ $f[0] } - $ip - 4) >> 2 if defined $label{ $f[0] };

        $offs = bits16 $f[0];

        $instr = pack_instruction $op, '00000', '00000', $offs;
        $instr_bin = join '_',    $op, '00000', '00000', $offs;

    }
    elsif( $a eq 'BAL' ){

        $op  = '000001';

        $f[0] =  ($label{ $f[0] } - $ip - 4) >> 2 if defined $label{ $f[0] };

        $offs = bits16 $f[0];

        $instr = pack_instruction $op, '00000', '10001', $offs;
        $instr_bin = join '_',    $op, '00000', '10001', $offs;

    }
    elsif( $a eq 'BEQ' ){

        $op  = '000100';

        $f[2] =  ($label{ $f[2] } - $ip - 4) >> 2 if defined $label{ $f[2] };

        $rt   = bits5  $f[0];
        $rs   = bits5  $f[1];
        $offs = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $offs;
        $instr_bin = join '_',    $op, $rs, $rt, $offs;
    }
   elsif( $a eq 'BEQL' ){

        $op  = '010100';

        $f[2] =  ($label{ $f[2] } - $ip - 4) >> 2 if defined $label{ $f[2] };

        $rt   = bits5  $f[0];
        $rs   = bits5  $f[1];
        $offs = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $offs;
        $instr_bin = join '_',    $op, $rs, $rt, $offs;
    }
    elsif( $a eq 'BNEL' ){

        $op  = '010101';

        $f[2] =  ($label{ $f[2] } - $ip - 4) >> 2 if defined $label{ $f[2] };

        $rt   = bits5  $f[0];
        $rs   = bits5  $f[1];
        $offs = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $offs;
        $instr_bin = join '_',    $op, $rs, $rt, $offs;

    }
    elsif( $a eq 'BNE' ){

        $op  = '000101';

        $f[2] =  ($label{ $f[2] } - $ip - 4) >> 2 if defined $label{ $f[2] };

        $rt   = bits5  $f[0];
        $rs   = bits5  $f[1];
        $offs = bits16 $f[2];

        $instr = pack_instruction $op, $rs, $rt, $offs;
        $instr_bin = join '_',    $op, $rs, $rt, $offs;

    }


    elsif( $a eq 'BGEZ' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00001', $offs;
        $instr_bin = join '_',    $op, $rs, '00001', $offs;

    }
    elsif( $a eq 'BGEZAL' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '10001', $offs;
        $instr_bin = join '_',    $op, $rs, '10001', $offs;

    }
    elsif( $a eq 'BGEZALL' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '10011', $offs;
        $instr_bin = join '_',    $op, $rs, '10011', $offs;

    }

    elsif( $a eq 'BGEZL' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00011', $offs;
        $instr_bin = join '_',    $op, $rs, '00011', $offs;

    }

    elsif( $a eq 'BGTZL' ){

        $op  = '010111';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00000', $offs;
        $instr_bin = join '_',    $op, $rs, '00000', $offs;

    }
    elsif( $a eq 'BGTZ' ){

        $op  = '000111';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00000', $offs;
        $instr_bin = join '_',    $op, $rs, '00000', $offs;

    }

    elsif( $a eq 'BLEZL' ){

        $op  = '010110';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00000', $offs;
        $instr_bin = join '_',    $op, $rs, '00000', $offs;

    }
    elsif( $a eq 'BLEZ' ){

        $op  = '000110';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00000', $offs;
        $instr_bin = join '_',    $op, $rs, '00000', $offs;

    }


    elsif( $a eq 'BLTZ' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00000', $offs;
        $instr_bin = join '_',    $op, $rs, '00000', $offs;

    }
    elsif( $a eq 'BLTZAL' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '10000', $offs;
        $instr_bin = join '_',    $op, $rs, '10000', $offs;

    }
    elsif( $a eq 'BLTZALL' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '10010', $offs;
        $instr_bin = join '_',    $op, $rs, '10010', $offs;

    }


    elsif( $a eq 'BLTZL' ){

        $op  = '000001';

        $f[1] =  ($label{ $f[1] } - $ip - 4) >> 2 if defined $label{ $f[1] };

        $rs   = bits5  $f[0];
        $offs = bits16 $f[1];

        $instr = pack_instruction $op, $rs, '00010', $offs;
        $instr_bin = join '_',    $op, $rs, '00010', $offs;

    }

    elsif( $a eq 'DSRL32' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $sa  = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '111110';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '111110';

    }

    elsif( $a eq 'SRA' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $sa  = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '000011';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '000011';

    }

    elsif( $a eq 'SRAV' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '000111';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '000111';         
    }




    elsif( $a eq 'DEXT' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos = bits5  $f[2];
        $size1 = bits5 ($f[3] - 1);

        $instr = pack_instruction $op, $rs, $rt, $size1, $pos, '000011';
        $instr_bin = join '_',    $op, $rs, $rt, $size1, $pos, '000011';

    }
    elsif( $a eq 'DEXTM' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos = bits5  $f[2];
        $size1 = bits5 ($f[3] - 33);

        $instr = pack_instruction $op, $rs, $rt, $size1, $pos, '000001';
        $instr_bin = join '_',    $op, $rs, $rt, $size1, $pos, '000001';

    }
    elsif( $a eq 'DEXTU' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos1 = bits5  ($f[2] - 32);
        $size1 = bits5 ($f[3] - 1);

        $instr = pack_instruction $op, $rs, $rt, $size1, $pos1, '000010';
        $instr_bin = join '_',    $op, $rs, $rt, $size1, $pos1, '000010';

    }
    elsif( $a eq 'EXT' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos1 = bits5 $f[2];
        $size1 = bits5 ($f[3] - 1);

        $instr = pack_instruction $op, $rs, $rt, $size1, $pos1, '000000';
        $instr_bin = join '_',    $op, $rs, $rt, $size1, $pos1, '000000';

    }



    elsif( $a eq 'DINS' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos = bits5  $f[2];
        $pos_size_1 = bits5 ($f[3] + $f[2] - 1);        # pos + size - 1

        $instr = pack_instruction $op, $rs, $rt, $pos_size_1, $pos, '000111';
        $instr_bin = join '_',    $op, $rs, $rt, $pos_size_1, $pos, '000111';

    }
    elsif( $a eq 'DINSM' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos = bits5  $f[2];
        $pos_size_1 = bits5 ($f[3] + $f[2] - 33);        # pos + size - 33

        $instr = pack_instruction $op, $rs, $rt, $pos_size_1, $pos, '000101';
        $instr_bin = join '_',    $op, $rs, $rt, $pos_size_1, $pos, '000101';

    }
    elsif( $a eq 'DINSU' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos_1 = bits5  ($f[2] - 32);                    # pos - 32
        $pos_size_1 = bits5 ($f[3] + $f[2] - 33);        # pos + size - 33

        $instr = pack_instruction $op, $rs, $rt, $pos_size_1, $pos_1, '000110';
        $instr_bin = join '_',    $op, $rs, $rt, $pos_size_1, $pos_1, '000110';

    }
    elsif( $a eq 'INS' ){

        $op  = '011111';

        $rt  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $pos = bits5  $f[2];
        $pos_size_1 = bits5 ($f[3] + $f[2] - 1);        # pos + size - 1

        $instr = pack_instruction $op, $rs, $rt, $pos_size_1, $pos, '000100';
        $instr_bin = join '_',    $op, $rs, $rt, $pos_size_1, $pos, '000100';

    }



    elsif( $a eq 'ROTR' ){

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $sa  = bits5  $f[2];

        $instr = pack_instruction '000000', '00001', $rt, $rd, $sa, '000010';
        $instr_bin = join '_',    '000000', '00001', $rt, $rd, $sa, '000010';

    }
    elsif( $a eq 'DROTR' ){

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $sa  = bits5  $f[2];

        $instr = pack_instruction '000000', '00001', $rt, $rd, $sa, '111010';
        $instr_bin = join '_',    '000000', '00001', $rt, $rd, $sa, '111010';

    }
    elsif( $a eq 'DROTR32' ){

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $sa  = bits5  $f[2];

        $instr = pack_instruction '000000', '00001', $rt, $rd, $sa, '111110';
        $instr_bin = join '_',    '000000', '00001', $rt, $rd, $sa, '111110';

    }
    elsif( $a eq 'DROTRV' ){

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00001', '010110';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00001', '010110';

    }
    elsif( $a eq 'ROTRV' ){

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00001', '000110';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00001', '000110';

    }




    elsif( $a eq 'DSRA' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $sa  = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '111011';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '111011';

    }
    elsif( $a eq 'DSRA32' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $sa  = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '111111';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '111111';

    }

    elsif( $a eq 'DSRAV' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '010111';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '010111';         
    }




    elsif( $a eq 'J' ){

        $op  = '000010';

        $f[0] =  $label{ $f[0] } >> 2 if defined $label{ $f[0] };

        $offs = bits26 $f[0];
        
        $instr = pack_instruction $op, $offs;
        $instr_bin = join '_',    $op, $offs;

    }
    elsif( $a eq 'JAL' ){

        $op  = '000011';

        $f[0] =  $label{ $f[0] } >> 2 if defined $label{ $f[0] };

        $offs = bits26 $f[0];

        $instr = pack_instruction $op, $offs;
        $instr_bin = join '_',    $op, $offs;

    }
    elsif( $a eq 'LB' ){                # LB $5, 1000h(4)

        $op  = '100000';
        
    $f[1] = eval_offset_expr $f[1];

        $offs = bits16  $f[1];
        $base = bits5   $f[2];
        $rt   = bits5   $f[0];

        $instr = pack_instruction $op, $base, $rt, $offs;
        $instr_bin = join '_',    $op, $base, $rt, $offs;

    }
    elsif( $a eq 'LD' ){

        $op  = '110111';

    $f[1] = eval_offset_expr $f[1];

        $offs = bits16  $f[1];
        $base = bits5   $f[2];
        $rt   = bits5   $f[0];

        $instr = pack_instruction $op, $base, $rt, $offs;
        $instr_bin = join '_',    $op, $base, $rt, $offs;

    }
    elsif( $a eq 'LUI' ){               # LUI $6, 12345

        $op  = '001111';

    $f[1] = eval_offset_expr $f[1];

        $rt  = bits5  $f[0];
        $imm = bits16 $f[1];

        $instr = pack_instruction $op, '00000', $rt, $imm;
        $instr_bin = join '_',    $op, '00000', $rt, $imm;

    }



    elsif( $a eq 'SLLV' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '000100';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '000100';         
    }
    elsif( $a eq 'DSLLV' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '010100';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '010100';         
    }

    elsif( $a eq 'SRLV' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '000110';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '000110';         
    }
    elsif( $a eq 'DSRLV' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];
        $rs  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '010110';         # а в томе 2 почему-то '00001', '010110' ???
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '010110';         
    }


    elsif( $a eq 'RDHWR' ){

        $op  = '011111';
               
        $rt  = bits5  $f[0];
        $rd  = bits5  $f[1];

        $instr = pack_instruction $op, '00000', $rt, $rd, '00000', '111011';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, '00000', '111011';         
    }

    elsif( $a eq 'RDPGPR' ){

        $op  = '010000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];

        $instr = pack_instruction $op, '01010', $rt, $rd, '00000', '000000';
        $instr_bin = join '_',    $op, '01010', $rt, $rd, '00000', '000000';         
    }

    elsif( $a eq 'WRPGPR' ){

        $op  = '010000';
               
        $rd  = bits5  $f[0];
        $rt  = bits5  $f[1];

        $instr = pack_instruction $op, '01110', $rt, $rd, '00000', '000000';
        $instr_bin = join '_',    $op, '01110', $rt, $rd, '00000', '000000';         
    }

    elsif( $a eq 'OR' ){

        $op  = '000000';
               
        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '100101';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '100101';         
    }
    elsif( $a eq 'ORI' ){

        $op  = '001101';

    $f[2] = eval_offset_expr $f[2];

        $rs   = bits5   $f[1];
        $rt   = bits5   $f[0];
        $imm  = bits16  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $imm;
        $instr_bin = join '_',    $op, $rs, $rt, $imm;

    }
    elsif( $a eq 'SB' ){

        $op  = '101000';

    $f[1] = eval_offset_expr $f[1];

        $offs = bits16 $f[1];
        $base = bits5  $f[2];
        $rt   = bits5  $f[0];

        $instr = pack_instruction $op, $base, $rt, $offs;
        $instr_bin = join '_',    $op, $base, $rt, $offs;

    }
    elsif( $a eq 'SD' ){

        $op  = '111111';

    $f[1] = eval_offset_expr $f[1];

        $offs = bits16 $f[1];
        $base = bits5  $f[2];
        $rt   = bits5  $f[0];

        $instr = pack_instruction $op, $base, $rt, $offs;
        $instr_bin = join '_',    $op, $base, $rt, $offs;

    }


    elsif( $a eq 'SLL' ){

        $op  = '000000';

        $rt   = bits5  $f[1];
        $rd   = bits5  $f[0];
        $sa   = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '000000';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '000000';

    }

    elsif( $a eq 'DSLL' ){

        $op  = '000000';

        $rt   = bits5  $f[1];
        $rd   = bits5  $f[0];
        $sa   = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '111000';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '111000';

    }
    elsif( $a eq 'DSLL32' ){

        $op  = '000000';

        $rt   = bits5  $f[1];
        $rd   = bits5  $f[0];
        $sa   = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '111100';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '111100';

    }

    elsif( $a eq 'DSRL' ){

        $op  = '000000';

        $rt   = bits5  $f[1];
        $rd   = bits5  $f[0];
        $sa   = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '111010';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '111010';

    }

    elsif( $a eq 'SRL' ){

        $op  = '000000';

        $rt   = bits5  $f[1];
        $rd   = bits5  $f[0];
        $sa   = bits5  $f[2];

        $instr = pack_instruction $op, '00000', $rt, $rd, $sa, '000010';
        $instr_bin = join '_',    $op, '00000', $rt, $rd, $sa, '000010';

    }
    elsif( $a eq 'SUB' ){

        $op  = '000000';

        $rd  = bits5  $f[0];
        $rs  = bits5  $f[1];
        $rt  = bits5  $f[2];

        $instr = pack_instruction $op, $rs, $rt, $rd, '00000', '100010';
        $instr_bin = join '_',    $op, $rs, $rt, $rd, '00000', '100010';

    }





    elsif( $a eq 'BREAK' ){

        $code  = bits20   $f[0];

        $instr = pack_instruction '000000', $code, '001101';
        $instr_bin = join '_',    '000000', $code, '001101';

    }

    elsif( $a eq 'CLO' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rd, $rd, '00000', '100001';
        $instr_bin = join '_',    '011100', $rs, $rd, $rd, '00000', '100001';

    }

    elsif( $a eq 'CLZ' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rd, $rd, '00000', '100000';
        $instr_bin = join '_',    '011100', $rs, $rd, $rd, '00000', '100000';

    }

    elsif( $a eq 'DCLO' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rd, $rd, '00000', '100101';
        $instr_bin = join '_',    '011100', $rs, $rd, $rd, '00000', '100101';

    }

    elsif( $a eq 'DCLZ' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rd, $rd, '00000', '100100';
        $instr_bin = join '_',    '011100', $rs, $rd, $rd, '00000', '100100';

    }

    elsif( $a eq 'DDIV' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011110';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011110';

    }

    elsif( $a eq 'DDIVU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011111';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011111';

    }

    elsif( $a eq 'DERET' ){

 
        $instr = pack_instruction '010000', '1', '0000000000000000000', '011111';
        $instr_bin = join '_',    '010000', '1', '0000000000000000000', '011111';

    }


    elsif( $a eq 'EI' ){

        $rt    = bits5    $f[0];

        $instr = pack_instruction '010000', '01011', $rt, '01100', '00000', '100000';
        $instr_bin = join '_',    '010000', '01011', $rt, '01100', '00000', '100000';

    }

    elsif( $a eq 'DI' ){

        $rt    = bits5    $f[0];

        $instr = pack_instruction '010000', '01011', $rt, '01100', '00000', '000000';
        $instr_bin = join '_',    '010000', '01011', $rt, '01100', '00000', '000000';

    }




    elsif( $a eq 'DSBH' ){

        $rd    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011111', '00000', $rt, $rd, '00010', '100100';
        $instr_bin = join '_',    '011111', '00000', $rt, $rd, '00010', '100100';

    }

    elsif( $a eq 'DSHD' ){

        $rd    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011111', '00000', $rt, $rd, '00101', '100100';
        $instr_bin = join '_',    '011111', '00000', $rt, $rd, '00101', '100100';

    }

    elsif( $a eq 'WSBH' ){

        $rd    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011111', '00000', $rt, $rd, '00010', '100000';
        $instr_bin = join '_',    '011111', '00000', $rt, $rd, '00010', '100000';

    }




    elsif( $a eq 'DIV' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011010';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011010';

    }

    elsif( $a eq 'DIVU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011011';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011011';

    }

    elsif( $a eq 'DMFC0' ){

        $rt    = bits5    $f[0];
        $rd    = bits5    $f[1];
        $sel   = bits3    $f[2];

        $instr = pack_instruction '010000', '00001', $rt, $rd, '00000000', $sel;
        $instr_bin = join '_',    '010000', '00001', $rt, $rd, '00000000', $sel;

    }

    elsif( $a eq 'DMTC0' ){

        $rt    = bits5    $f[0];
        $rd    = bits5    $f[1];
        $sel   = bits3    $f[2];

        $instr = pack_instruction '010000', '00101', $rt, $rd, '00000000', $sel;
        $instr_bin = join '_',    '010000', '00101', $rt, $rd, '00000000', $sel;

    }

    elsif( $a eq 'DMULT' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011100';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011100';

    }

    elsif( $a eq 'DMULTU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011101';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011101';

    }

    elsif( $a eq 'ERET' ){

 
        $instr = pack_instruction '010000', '1', '0000000000000000000', '011000';
        $instr_bin = join '_',    '010000', '1', '0000000000000000000', '011000';

    }

    elsif( $a eq 'JALR' ){

        if( defined $f[1] ){

            $rd    = bits5    $f[0];
            $rs    = bits5    $f[1];
        }
        else
        {
            $rd    = bits5    31;
            $rs    = bits5    $f[0];
        }

        $instr = pack_instruction '000000', $rs, '00000', $rd, '00000', '001001';
        $instr_bin = join '_',    '000000', $rs, '00000', $rd, '00000', '001001';

    }

    elsif( $a eq 'JR' ){

        $rs    = bits5    $f[0];

        $instr = pack_instruction '000000', $rs, '0000000000', '00000', '001000';
        $instr_bin = join '_',    '000000', $rs, '0000000000', '00000', '001000';

    }

    elsif( $a eq 'LBU' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '100100', $base, $rt, $offs;
        $instr_bin = join '_',    '100100', $base, $rt, $offs;

    }

    elsif( $a eq 'LDL' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '011010', $base, $rt, $offs;
        $instr_bin = join '_',    '011010', $base, $rt, $offs;

    }

    elsif( $a eq 'LDR' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '011011', $base, $rt, $offs;
        $instr_bin = join '_',    '011011', $base, $rt, $offs;

    }

    elsif( $a eq 'LH' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '100001', $base, $rt, $offs;
        $instr_bin = join '_',    '100001', $base, $rt, $offs;

    }

    elsif( $a eq 'LHU' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '100101', $base, $rt, $offs;
        $instr_bin = join '_',    '100101', $base, $rt, $offs;

    }

    elsif( $a eq 'LL' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '110000', $base, $rt, $offs;
        $instr_bin = join '_',    '110000', $base, $rt, $offs;

    }

    elsif( $a eq 'LLD' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '110100', $base, $rt, $offs;
        $instr_bin = join '_',    '110100', $base, $rt, $offs;

    }

    elsif( $a eq 'LW' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '100011', $base, $rt, $offs;
        $instr_bin = join '_',    '100011', $base, $rt, $offs;

    }

    elsif( $a eq 'LWL' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '100010', $base, $rt, $offs;
        $instr_bin = join '_',    '100010', $base, $rt, $offs;

    }

    elsif( $a eq 'LWR' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '100110', $base, $rt, $offs;
        $instr_bin = join '_',    '100110', $base, $rt, $offs;

    }

    elsif( $a eq 'LWU' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '100111', $base, $rt, $offs;
        $instr_bin = join '_',    '100111', $base, $rt, $offs;

    }

    elsif( $a eq 'MADD' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rt, '00000', '00000', '000000';
        $instr_bin = join '_',    '011100', $rs, $rt, '00000', '00000', '000000';

    }

    elsif( $a eq 'MADDU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rt, '00000', '00000', '000001';
        $instr_bin = join '_',    '011100', $rs, $rt, '00000', '00000', '000001';

    }

    elsif( $a eq 'MFC0' ){

        $rt    = bits5    $f[0];
        $rd    = bits5    $f[1];
        $sel   = bits3    $f[2];

        $instr = pack_instruction '010000', '00000', $rt, $rd, '00000000', $sel;
        $instr_bin = join '_',    '010000', '00000', $rt, $rd, '00000000', $sel;

    }

    elsif( $a eq 'MFHI' ){

        $rd    = bits5    $f[0];

        $instr = pack_instruction '000000', '0000000000', $rd, '00000', '010000';
        $instr_bin = join '_',    '000000', '0000000000', $rd, '00000', '010000';

    }

    elsif( $a eq 'MFLO' ){

        $rd    = bits5    $f[0];

        $instr = pack_instruction '000000', '0000000000', $rd, '00000', '010010';
        $instr_bin = join '_',    '000000', '0000000000', $rd, '00000', '010010';

    }

    elsif( $a eq 'MOVN' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '001011';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '001011';

    }

    elsif( $a eq 'MOVZ' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '001010';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '001010';

    }

    elsif( $a eq 'MSUB' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rt, '00000', '00000', '000100';
        $instr_bin = join '_',    '011100', $rs, $rt, '00000', '00000', '000100';

    }

    elsif( $a eq 'MSUBU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011100', $rs, $rt, '00000', '00000', '000101';
        $instr_bin = join '_',    '011100', $rs, $rt, '00000', '00000', '000101';

    }

    elsif( $a eq 'MTC0' ){

        $rt    = bits5    $f[0];
        $rd    = bits5    $f[1];
        $sel   = bits3    $f[2];

        $instr = pack_instruction '010000', '00100', $rt, $rd, '00000000', $sel;
        $instr_bin = join '_',    '010000', '00100', $rt, $rd, '00000000', $sel;

    }

    elsif( $a eq 'MTHI' ){

        $rs    = bits5    $f[0];

        $instr = pack_instruction '000000', $rs, '000000000000000', '010001';
        $instr_bin = join '_',    '000000', $rs, '000000000000000', '010001';

    }

    elsif( $a eq 'MTLO' ){

        $rs    = bits5    $f[0];

        $instr = pack_instruction '000000', $rs, '000000000000000', '010011';
        $instr_bin = join '_',    '000000', $rs, '000000000000000', '010011';

    }

    elsif( $a eq 'MUL' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '011100', $rs, $rt, $rd, '00000', '000010';
        $instr_bin = join '_',    '011100', $rs, $rt, $rd, '00000', '000010';

    }

    elsif( $a eq 'MULT' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011000';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011000';

    }

    elsif( $a eq 'MULTU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '000000', $rs, $rt, '0000000000', '011001';
        $instr_bin = join '_',    '000000', $rs, $rt, '0000000000', '011001';

    }

    elsif( $a eq 'NOR' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '100111';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '100111';

    }

    elsif( $a eq 'AND' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '100100';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '100100';

    }

    elsif( $a eq 'PREF' ){

    $f[1] = eval_offset_expr $f[1];

        $hint  = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '110011', $base, $hint, $offs;
        $instr_bin = join '_',    '110011', $base, $hint, $offs;

    }

    elsif( $a eq 'PREFX' ){

        $hint  = bits5    $f[0];
        $index = bits5    $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '010011', $base, $index, $hint, '00000', '001111';
        $instr_bin = join '_',    '010011', $base, $index, $hint, '00000', '001111';

    }

    elsif( $a eq 'SC' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '111000', $base, $rt, $offs;
        $instr_bin = join '_',    '111000', $base, $rt, $offs;

    }

    elsif( $a eq 'SCD' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '111100', $base, $rt, $offs;
        $instr_bin = join '_',    '111100', $base, $rt, $offs;

    }

    elsif( $a eq 'SDL' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '101100', $base, $rt, $offs;
        $instr_bin = join '_',    '101100', $base, $rt, $offs;

    }

    elsif( $a eq 'SDR' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '101101', $base, $rt, $offs;
        $instr_bin = join '_',    '101101', $base, $rt, $offs;

    }




    elsif( $a eq 'SEB' ){

        $rd    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011111', '00000', $rt, $rd, '10000', '100000';
        $instr_bin = join '_',    '011111', '00000', $rt, $rd, '10000', '100000';

    }
    elsif( $a eq 'SEH' ){

        $rd    = bits5    $f[0];
        $rt    = bits5    $f[1];

        $instr = pack_instruction '011111', '00000', $rt, $rd, '11000', '100000';
        $instr_bin = join '_',    '011111', '00000', $rt, $rd, '11000', '100000';

    }






    elsif( $a eq 'SH' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '101001', $base, $rt, $offs;
        $instr_bin = join '_',    '101001', $base, $rt, $offs;

    }

    elsif( $a eq 'SLT' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '101010';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '101010';

    }

    elsif( $a eq 'SLTI' ){

    $f[2] = eval_offset_expr $f[2];

        $rt    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $imm   = bits16   $f[2];

        $instr = pack_instruction '001010', $rs, $rt, $imm;
        $instr_bin = join '_',    '001010', $rs, $rt, $imm;

    }

    elsif( $a eq 'SLTIU' ){

    $f[2] = eval_offset_expr $f[2];

        $rt    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $imm   = bits16   $f[2];

        $instr = pack_instruction '001011', $rs, $rt, $imm;
        $instr_bin = join '_',    '001011', $rs, $rt, $imm;

    }

    elsif( $a eq 'SLTU' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '101011';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '101011';

    }

    elsif( $a eq 'SSNOP' ){

 
        $instr = pack_instruction '000000', '00000', '00000', '00000', '00001', '000000';
        $instr_bin = join '_',    '000000', '00000', '00000', '00000', '00001', '000000';

    }

    elsif( $a eq 'SUBU' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '100011';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '100011';

    }

    elsif( $a eq 'SW' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '101011', $base, $rt, $offs;
        $instr_bin = join '_',    '101011', $base, $rt, $offs;

    }

    elsif( $a eq 'SWL' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '101010', $base, $rt, $offs;
        $instr_bin = join '_',    '101010', $base, $rt, $offs;

    }

    elsif( $a eq 'SWR' ){

    $f[1] = eval_offset_expr $f[1];

        $rt    = bits5    $f[0];
        $offs  = bits16   $f[1];
        $base  = bits5    $f[2];

        $instr = pack_instruction '101110', $base, $rt, $offs;
        $instr_bin = join '_',    '101110', $base, $rt, $offs;

    }

    elsif( $a eq 'SYNC' ){

 
        $instr = pack_instruction '000000', '000000000000000', '00000', '001111';
        $instr_bin = join '_',    '000000', '000000000000000', '00000', '001111';

    }

    elsif( $a eq 'SYSCALL' ){

        $code  = bits20   $f[0];

        $instr = pack_instruction '000000', $code, '001100';
        $instr_bin = join '_',    '000000', $code, '001100';

    }

    elsif( $a eq 'TEQ' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];
        $code_ = bits10   $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $code_, '110100';
        $instr_bin = join '_',    '000000', $rs, $rt, $code_, '110100';

    }

    elsif( $a eq 'TEQI' ){

    $f[1] = eval_offset_expr $f[1];

        $rs    = bits5    $f[0];
        $imm   = bits16   $f[1];

        $instr = pack_instruction '000001', $rs, '01100', $imm;
        $instr_bin = join '_',    '000001', $rs, '01100', $imm;

    }

    elsif( $a eq 'TGE' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];
        $code_ = bits10   $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $code_, '110000';
        $instr_bin = join '_',    '000000', $rs, $rt, $code_, '110000';

    }

    elsif( $a eq 'TGEI' ){

    $f[1] = eval_offset_expr $f[1];

        $rs    = bits5    $f[0];
        $imm   = bits16   $f[1];

        $instr = pack_instruction '000001', $rs, '01000', $imm;
        $instr_bin = join '_',    '000001', $rs, '01000', $imm;

    }

    elsif( $a eq 'TGEIU' ){

    $f[1] = eval_offset_expr $f[1];

        $rs    = bits5    $f[0];
        $imm   = bits16   $f[1];

        $instr = pack_instruction '000001', $rs, '01001', $imm;
        $instr_bin = join '_',    '000001', $rs, '01001', $imm;

    }

    elsif( $a eq 'TGEU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];
        $code_ = bits10   $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $code_, '110001';
        $instr_bin = join '_',    '000000', $rs, $rt, $code_, '110001';

    }

    elsif( $a eq 'TLBP' ){

 
        $instr = pack_instruction '010000', '1', '0000000000000000000', '001000';
        $instr_bin = join '_',    '010000', '1', '0000000000000000000', '001000';

    }

    elsif( $a eq 'TLBR' ){

 
        $instr = pack_instruction '010000', '1', '0000000000000000000', '000001';
        $instr_bin = join '_',    '010000', '1', '0000000000000000000', '000001';

    }

    elsif( $a eq 'TLBWI' ){

 
        $instr = pack_instruction '010000', '1', '0000000000000000000', '000010';
        $instr_bin = join '_',    '010000', '1', '0000000000000000000', '000010';

    }

    elsif( $a eq 'TLBWR' ){

 
        $instr = pack_instruction '010000', '1', '0000000000000000000', '000110';
        $instr_bin = join '_',    '010000', '1', '0000000000000000000', '000110';

    }

    elsif( $a eq 'TLT' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];
        $code_ = bits10   $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $code_, '110010';
        $instr_bin = join '_',    '000000', $rs, $rt, $code_, '110010';

    }

    elsif( $a eq 'TLTI' ){

    $f[1] = eval_offset_expr $f[1];

        $rs    = bits5    $f[0];
        $imm   = bits16   $f[1];

        $instr = pack_instruction '000001', $rs, '01010', $imm;
        $instr_bin = join '_',    '000001', $rs, '01010', $imm;

    }

    elsif( $a eq 'TLTIU' ){

    $f[1] = eval_offset_expr $f[1];

        $rs    = bits5    $f[0];
        $imm   = bits16   $f[1];

        $instr = pack_instruction '000001', $rs, '01011', $imm;
        $instr_bin = join '_',    '000001', $rs, '01011', $imm;

    }

    elsif( $a eq 'TLTU' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];
        $code_ = bits10   $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $code_, '110011';
        $instr_bin = join '_',    '000000', $rs, $rt, $code_, '110011';

    }

    elsif( $a eq 'TNE' ){

        $rs    = bits5    $f[0];
        $rt    = bits5    $f[1];
        $code_ = bits10   $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $code_, '110110';
        $instr_bin = join '_',    '000000', $rs, $rt, $code_, '110110';

    }

    elsif( $a eq 'TNEI' ){

    $f[1] = eval_offset_expr $f[1];

        $rs    = bits5    $f[0];
        $imm   = bits16   $f[1];

        $instr = pack_instruction '000001', $rs, '01110', $imm;
        $instr_bin = join '_',    '000001', $rs, '01110', $imm;

    }

    elsif( $a eq 'WAIT' ){

 
        $instr = pack_instruction '010000', '1', '0000000000000000000', '100000';
        $instr_bin = join '_',    '010000', '1', '0000000000000000000', '100000';

    }

    elsif( $a eq 'XOR' ){

        $rd    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $rt    = bits5    $f[2];

        $instr = pack_instruction '000000', $rs, $rt, $rd, '00000', '100110';
        $instr_bin = join '_',    '000000', $rs, $rt, $rd, '00000', '100110';

    }

    elsif( $a eq 'XORI' ){

    $f[2] = eval_offset_expr $f[2];

        $rt    = bits5    $f[0];
        $rs    = bits5    $f[1];
        $imm   = bits16   $f[2];

        $instr = pack_instruction '001110', $rs, $rt, $imm;
        $instr_bin = join '_',    '001110', $rs, $rt, $imm;

    }

    elsif( $a eq 'EHB' ){
 
        $instr = pack_instruction '00000000000000000000000011000000';
        $instr_bin =            '000000_00000_00000_00000_00011_000000';
    }

    elsif( $a eq 'NOP' ){

        $instr = pack_instruction '00000000000000000000000000000000';
        $instr_bin =            '000000_00000_00000_00000_00000_000000';
    }
    else {  die "\n$a - unrecognized instruction\n";  }



    if( $opt_t || $opt_x )
    {
        $ip_hex = hex8 $ip;
        $instr_hex = hex8( oct( '0b' . $instr_bin ));

        print FT "$ip_hex / $instr_hex   $instr_bin    \t$printable_string\n"  if $opt_t;
        print FT "$ip_hex / $instr_hex\n"                       if $opt_x;

    }
    else
    {
        print FT $instr;
    }
    $ip += 4;
}
