select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 839 and 839+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'blue' or i_color = 'lavender') and 
        (i_units = 'Dram' or i_units = 'Gram') and
        (i_size = 'economy' or i_size = 'large')
        ) or
        (i_category = 'Women' and
        (i_color = 'firebrick' or i_color = 'rose') and
        (i_units = 'N/A' or i_units = 'Pallet') and
        (i_size = 'N/A' or i_size = 'small')
        ) or
        (i_category = 'Men' and
        (i_color = 'wheat' or i_color = 'gainsboro') and
        (i_units = 'Case' or i_units = 'Box') and
        (i_size = 'petite' or i_size = 'medium')
        ) or
        (i_category = 'Men' and
        (i_color = 'orange' or i_color = 'seashell') and
        (i_units = 'Bunch' or i_units = 'Ounce') and
        (i_size = 'economy' or i_size = 'large')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'chiffon' or i_color = 'powder') and 
        (i_units = 'Lb' or i_units = 'Cup') and
        (i_size = 'economy' or i_size = 'large')
        ) or
        (i_category = 'Women' and
        (i_color = 'peach' or i_color = 'ghost') and
        (i_units = 'Pound' or i_units = 'Bundle') and
        (i_size = 'N/A' or i_size = 'small')
        ) or
        (i_category = 'Men' and
        (i_color = 'lime' or i_color = 'goldenrod') and
        (i_units = 'Ton' or i_units = 'Carton') and
        (i_size = 'petite' or i_size = 'medium')
        ) or
        (i_category = 'Men' and
        (i_color = 'cream' or i_color = 'midnight') and
        (i_units = 'Gross' or i_units = 'Each') and
        (i_size = 'economy' or i_size = 'large')
        )))) > 0
 order by i_product_name
 limit 100;

