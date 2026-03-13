select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 747 and 747+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'azure' or i_color = 'hot') and 
        (i_units = 'Cup' or i_units = 'Case') and
        (i_size = 'medium' or i_size = 'economy')
        ) or
        (i_category = 'Women' and
        (i_color = 'aquamarine' or i_color = 'chocolate') and
        (i_units = 'Tbl' or i_units = 'Each') and
        (i_size = 'extra large' or i_size = 'large')
        ) or
        (i_category = 'Men' and
        (i_color = 'lace' or i_color = 'dim') and
        (i_units = 'Oz' or i_units = 'Dram') and
        (i_size = 'petite' or i_size = 'small')
        ) or
        (i_category = 'Men' and
        (i_color = 'cornflower' or i_color = 'tan') and
        (i_units = 'Ton' or i_units = 'Unknown') and
        (i_size = 'medium' or i_size = 'economy')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'ivory' or i_color = 'burnished') and 
        (i_units = 'Gross' or i_units = 'Bundle') and
        (i_size = 'medium' or i_size = 'economy')
        ) or
        (i_category = 'Women' and
        (i_color = 'lemon' or i_color = 'saddle') and
        (i_units = 'Carton' or i_units = 'Bunch') and
        (i_size = 'extra large' or i_size = 'large')
        ) or
        (i_category = 'Men' and
        (i_color = 'black' or i_color = 'khaki') and
        (i_units = 'Dozen' or i_units = 'Box') and
        (i_size = 'petite' or i_size = 'small')
        ) or
        (i_category = 'Men' and
        (i_color = 'gainsboro' or i_color = 'lime') and
        (i_units = 'Tsp' or i_units = 'Lb') and
        (i_size = 'medium' or i_size = 'economy')
        )))) > 0
 order by i_product_name
 limit 100;

